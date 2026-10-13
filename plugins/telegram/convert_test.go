package main

import (
	"testing"

	"github.com/gotd/td/telegram/message/peer"
	"github.com/gotd/td/tg"
)

func TestChatsKeepTheirAppTitlesAndKinds(t *testing.T) {
	entities := peer.NewEntities(
		map[int64]*tg.User{
			7: {ID: 7, FirstName: "张", LastName: "三"},
			8: {ID: 8, Username: "lisi"},
			9: {ID: 9, Self: true, FirstName: "Me"},
		},
		map[int64]*tg.Chat{20: {ID: 20, Title: "周末球局"}},
		map[int64]*tg.Channel{30: {ID: 30, Title: "产品群", Megagroup: true}, 31: {ID: 31, Title: "公告"}},
	)
	last := &tg.Message{Date: 1_760_000_000}
	cases := []struct {
		peer  Peer
		title string
		kind  string
	}{
		{Peer{Kind: "user", ID: 7, AccessHash: 1}, "张 三", "private"},
		{Peer{Kind: "user", ID: 8, AccessHash: 1}, "lisi", "private"},
		{Peer{Kind: "chat", ID: 20}, "周末球局", "group"},
		{Peer{Kind: "channel", ID: 30, AccessHash: 2}, "产品群", "group"},
		{Peer{Kind: "channel", ID: 31, AccessHash: 3}, "公告", "channel"},
	}
	for _, c := range cases {
		chat, ok := chatOf(c.peer, entities, &tg.Dialog{UnreadCount: 2}, last)
		if !ok || chat.Title != c.title || chat.Type != c.kind || chat.ID != c.peer.ChatID() || chat.Unread != 2 {
			t.Errorf("%v → %+v", c.peer, chat)
		}
		if chat.LastMessageAt != "2025-10-09T08:53:20Z" {
			t.Errorf("last message time %q", chat.LastMessageAt)
		}
	}
	if _, ok := chatOf(Peer{Kind: "user", ID: 9}, entities, nil, nil); ok {
		t.Error("Saved Messages has no title the screen can match; it must not be listed")
	}
	if _, ok := chatOf(Peer{Kind: "user", ID: 404}, entities, nil, nil); ok {
		t.Error("a dialog without its user must not be listed")
	}
}

func TestPeersRoundTripThroughChatIDs(t *testing.T) {
	for _, input := range []tg.InputPeerClass{
		&tg.InputPeerUser{UserID: 7, AccessHash: 99},
		&tg.InputPeerChat{ChatID: 20},
		&tg.InputPeerChannel{ChannelID: 30, AccessHash: 98},
	} {
		p, ok := peerOf(input)
		if !ok {
			t.Fatalf("%T not addressed", input)
		}
		kind, number, err := parseChatID(p.ChatID())
		if err != nil || kind != p.Kind || number != p.ID {
			t.Errorf("%s parsed as %s %d %v", p.ChatID(), kind, number, err)
		}
		if back, _ := peerOf(p.input()); back != p {
			t.Errorf("%+v came back as %+v", p, back)
		}
	}
	if _, ok := peerOf(&tg.InputPeerSelf{}); ok {
		t.Error("self is not a listed chat")
	}
	for _, bad := range []string{"", "7", "user:", "user:x", "user:-1", "bot:7", "user:7:9"} {
		if _, _, err := parseChatID(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestHistoryIsOldestFirstWithSendersAndSummaries(t *testing.T) {
	who := newNames(
		[]tg.UserClass{&tg.User{ID: 7, FirstName: "王五"}},
		[]tg.ChatClass{&tg.Channel{ID: 31, Title: "公告"}},
	)
	page := []tg.MessageClass{
		&tg.Message{ID: 105, Out: true, Message: "好的", Date: 1_760_000_500, PeerID: &tg.PeerUser{UserID: 7},
			ReplyTo: &tg.MessageReplyHeader{ReplyToMsgID: 104}},
		&tg.Message{ID: 104, Message: "带上球拍", Date: 1_760_000_400, PeerID: &tg.PeerUser{UserID: 7},
			Media: &tg.MessageMediaPhoto{}},
		&tg.MessageService{ID: 103, Date: 1_760_000_300},
		&tg.Message{ID: 102, Date: 1_760_000_200, PeerID: &tg.PeerUser{UserID: 7},
			Media: &tg.MessageMediaDocument{Document: &tg.Document{Attributes: []tg.DocumentAttributeClass{
				&tg.DocumentAttributeVideo{}, &tg.DocumentAttributeAnimated{},
			}}}},
		&tg.Message{ID: 101, Message: "@me 周六打球？", Mentioned: true, Date: 1_760_000_100,
			PeerID: &tg.PeerChannel{ChannelID: 31}},
		&tg.Message{ID: 100, Message: "   ", Date: 1_760_000_000, PeerID: &tg.PeerUser{UserID: 7}},
	}
	got := messagesOf(page, who)
	want := []Message{
		{ID: "101", Sender: "公告", Text: "@me 周六打球？", Time: "2025-10-09T08:55:00Z", MentionsMe: true},
		{ID: "102", Sender: "王五", Text: "[动图]", Time: "2025-10-09T08:56:40Z"},
		{ID: "104", Sender: "王五", Text: "[图片] 带上球拍", Time: "2025-10-09T09:00:00Z"},
		{ID: "105", FromMe: true, Text: "好的", Time: "2025-10-09T09:01:40Z", ReplyTo: "104"},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d messages: %+v", len(got), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("message %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestMediaSummaries(t *testing.T) {
	doc := func(attributes ...tg.DocumentAttributeClass) tg.MessageMediaClass {
		return &tg.MessageMediaDocument{Document: &tg.Document{Attributes: attributes}}
	}
	cases := map[string]tg.MessageMediaClass{
		"":            &tg.MessageMediaWebPage{},
		"[贴纸]":        doc(&tg.DocumentAttributeFilename{FileName: "s.webp"}, &tg.DocumentAttributeSticker{}),
		"[语音]":        doc(&tg.DocumentAttributeAudio{Voice: true}),
		"[音频]":        doc(&tg.DocumentAttributeAudio{}, &tg.DocumentAttributeFilename{FileName: "a.mp3"}),
		"[视频消息]":      doc(&tg.DocumentAttributeVideo{RoundMessage: true}),
		"[视频]":        doc(&tg.DocumentAttributeVideo{}),
		"[文件 报价.pdf]": doc(&tg.DocumentAttributeFilename{FileName: "报价.pdf"}),
		"[文件]":        &tg.MessageMediaDocument{Document: &tg.DocumentEmpty{}},
		"[位置]":        &tg.MessageMediaGeo{},
		"[名片]":        &tg.MessageMediaContact{},
		"[投票] 几点集合？":  &tg.MessageMediaPoll{Poll: tg.Poll{Question: tg.TextWithEntities{Text: "几点集合？"}}},
		"[媒体]":        &tg.MessageMediaDice{},
	}
	for want, media := range cases {
		if got := mediaSummary(media); got != want {
			t.Errorf("%T: %q, want %q", media, got, want)
		}
	}
	if mediaSummary(nil) != "" {
		t.Error("no media, no summary")
	}
}

func TestUserNames(t *testing.T) {
	cases := map[string]*tg.User{
		"张三":              {FirstName: "张三"},
		"Ann Lee":         {FirstName: "Ann", LastName: "Lee"},
		"ann":             {Username: "ann"},
		"User 42":         {ID: 42},
		"Deleted Account": {Deleted: true, FirstName: "x"},
	}
	for want, u := range cases {
		if got := userName(u); got != want {
			t.Errorf("%+v → %q, want %q", u, got, want)
		}
	}
}
