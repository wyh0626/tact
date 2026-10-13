package main

import (
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/gotd/td/telegram/message/peer"
	"github.com/gotd/td/tg"
)

// Chat is one conversation in the plugin protocol (docs/ADAPTER.md).
type Chat struct {
	ID            string `json:"id"`
	Title         string `json:"title"`
	Type          string `json:"type,omitempty"`
	LastMessageAt string `json:"last_message_at,omitempty"`
	Unread        int    `json:"unread,omitempty"`
}

// Message is one message in the plugin protocol.
type Message struct {
	ID         string `json:"id"`
	Sender     string `json:"sender,omitempty"`
	FromMe     bool   `json:"from_me"`
	Text       string `json:"text"`
	Time       string `json:"time,omitempty"`
	ReplyTo    string `json:"reply_to,omitempty"`
	MentionsMe bool   `json:"mentions_me,omitempty"`
}

func unixTime(seconds int) string {
	if seconds <= 0 {
		return ""
	}
	return time.Unix(int64(seconds), 0).UTC().Format(time.RFC3339)
}

// userName is the name the Telegram app shows for a user: the name saved
// in contacts when there is one, as the server returns it.
func userName(u *tg.User) string {
	if u.Deleted {
		return "Deleted Account"
	}
	if name := strings.TrimSpace(u.FirstName + " " + u.LastName); name != "" {
		return name
	}
	if u.Username != "" {
		return u.Username
	}
	return "User " + strconv.FormatInt(u.ID, 10)
}

// peerOf is the API address of a dialog's input peer.
func peerOf(input tg.InputPeerClass) (Peer, bool) {
	switch p := input.(type) {
	case *tg.InputPeerUser:
		return Peer{Kind: "user", ID: p.UserID, AccessHash: p.AccessHash}, true
	case *tg.InputPeerChat:
		return Peer{Kind: "chat", ID: p.ChatID}, true
	case *tg.InputPeerChannel:
		return Peer{Kind: "channel", ID: p.ChannelID, AccessHash: p.AccessHash}, true
	}
	return Peer{}, false
}

func (p Peer) input() tg.InputPeerClass {
	switch p.Kind {
	case "user":
		return &tg.InputPeerUser{UserID: p.ID, AccessHash: p.AccessHash}
	case "chat":
		return &tg.InputPeerChat{ChatID: p.ID}
	default:
		return &tg.InputPeerChannel{ChannelID: p.ID, AccessHash: p.AccessHash}
	}
}

// chatOf lists a dialog. The self chat ("Saved Messages") is left out: its
// title differs by app language, so it cannot be told from the screen.
func chatOf(p Peer, entities peer.Entities, dialog tg.DialogClass, last tg.NotEmptyMessage) (Chat, bool) {
	chat := Chat{ID: p.ChatID()}
	switch p.Kind {
	case "user":
		u, ok := entities.User(p.ID)
		if !ok || u.Self {
			return Chat{}, false
		}
		chat.Title, chat.Type = userName(u), "private"
	case "chat":
		c, ok := entities.Chat(p.ID)
		if !ok {
			return Chat{}, false
		}
		chat.Title, chat.Type = c.Title, "group"
	case "channel":
		c, ok := entities.Channel(p.ID)
		if !ok {
			return Chat{}, false
		}
		chat.Title, chat.Type = c.Title, "channel"
		if c.Megagroup {
			chat.Type = "group"
		}
	}
	if d, ok := dialog.(*tg.Dialog); ok {
		chat.Unread = d.UnreadCount
	}
	if last != nil {
		chat.LastMessageAt = unixTime(last.GetDate())
	}
	return chat, chat.Title != ""
}

// names finds who sent a message among the users and chats that came
// with it.
type names struct {
	users map[int64]*tg.User
	chats map[int64]string
}

func newNames(users []tg.UserClass, chats []tg.ChatClass) names {
	n := names{users: map[int64]*tg.User{}, chats: map[int64]string{}}
	for _, u := range users {
		if user, ok := u.(*tg.User); ok {
			n.users[user.ID] = user
		}
	}
	for _, c := range chats {
		switch chat := c.(type) {
		case *tg.Chat:
			n.chats[chat.ID] = chat.Title
		case *tg.Channel:
			n.chats[chat.ID] = chat.Title
		}
	}
	return n
}

func (n names) of(from tg.PeerClass) string {
	switch p := from.(type) {
	case *tg.PeerUser:
		if u, ok := n.users[p.UserID]; ok {
			return userName(u)
		}
	case *tg.PeerChat:
		if title, ok := n.chats[p.ChatID]; ok {
			return title
		}
	case *tg.PeerChannel:
		if title, ok := n.chats[p.ChannelID]; ok {
			return title
		}
	}
	return ""
}

// messagesOf turns a history page (newest first, as the API returns it)
// into messages oldest first. Service messages (joins, pins) are skipped.
func messagesOf(page []tg.MessageClass, who names) []Message {
	out := make([]Message, 0, len(page))
	for _, item := range page {
		m, ok := item.(*tg.Message)
		if !ok {
			continue
		}
		text := strings.TrimSpace(m.Message)
		if summary := mediaSummary(m.Media); summary != "" {
			text = strings.TrimSpace(summary + " " + text)
		}
		if text == "" {
			continue
		}
		msg := Message{ID: strconv.Itoa(m.ID), FromMe: m.Out, Text: text, Time: unixTime(m.Date), MentionsMe: m.Mentioned}
		if !m.Out {
			// In a private chat the sender is the chat itself.
			from, ok := m.GetFromID()
			if !ok {
				from = m.PeerID
			}
			msg.Sender = who.of(from)
		}
		if r, ok := m.ReplyTo.(*tg.MessageReplyHeader); ok && r.ReplyToMsgID != 0 {
			msg.ReplyTo = strconv.Itoa(r.ReplyToMsgID)
		}
		out = append(out, msg)
	}
	slices.Reverse(out)
	return out
}

// mediaSummary stands in for media the model cannot see. Link previews
// add nothing: the link is in the text.
func mediaSummary(media tg.MessageMediaClass) string {
	switch m := media.(type) {
	case nil, *tg.MessageMediaEmpty, *tg.MessageMediaWebPage:
		return ""
	case *tg.MessageMediaPhoto:
		return "[图片]"
	case *tg.MessageMediaDocument:
		return documentSummary(m.Document)
	case *tg.MessageMediaGeo, *tg.MessageMediaGeoLive, *tg.MessageMediaVenue:
		return "[位置]"
	case *tg.MessageMediaContact:
		return "[名片]"
	case *tg.MessageMediaPoll:
		return strings.TrimSpace("[投票] " + m.Poll.Question.Text)
	default:
		return "[媒体]"
	}
}

func documentSummary(document tg.DocumentClass) string {
	doc, ok := document.(*tg.Document)
	if !ok {
		return "[文件]"
	}
	// A GIF is also a video, and a voice note also audio: the most
	// specific attribute wins, wherever it sits in the list.
	var sticker, voice, audio, round, animated, video bool
	file := ""
	for _, attribute := range doc.Attributes {
		switch a := attribute.(type) {
		case *tg.DocumentAttributeSticker:
			sticker = true
		case *tg.DocumentAttributeAudio:
			voice, audio = voice || a.Voice, true
		case *tg.DocumentAttributeVideo:
			round, video = round || a.RoundMessage, true
		case *tg.DocumentAttributeAnimated:
			animated = true
		case *tg.DocumentAttributeFilename:
			file = a.FileName
		}
	}
	switch {
	case sticker:
		return "[贴纸]"
	case voice:
		return "[语音]"
	case round:
		return "[视频消息]"
	case animated:
		return "[动图]"
	case video:
		return "[视频]"
	case audio:
		return "[音频]"
	case file != "":
		return "[文件 " + file + "]"
	default:
		return "[文件]"
	}
}
