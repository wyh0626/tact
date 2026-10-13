package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/gotd/td/session"
	"github.com/gotd/td/telegram"
	"github.com/gotd/td/telegram/auth"
	"github.com/gotd/td/telegram/query/dialogs"
	"github.com/gotd/td/tg"
)

var errSignedOut = errors.New("还没登录 Telegram：在 Tact 的聊天工具页运行「扫码登录」")

// The most chats listed, newest first; the header is matched against them.
const maxChats = 300

// newClient connects as the user's own session. The device name shows in
// Telegram's list of active sessions, so people can see and end it there.
func newClient(store Store, app App, updates telegram.UpdateHandler) *telegram.Client {
	return telegram.NewClient(app.ID, app.Hash, telegram.Options{
		SessionStorage: &session.FileStorage{Path: store.SessionPath()},
		UpdateHandler:  updates,
		Device: telegram.DeviceConfig{
			DeviceModel:    "Tact",
			SystemVersion:  "macOS",
			AppVersion:     version,
			SystemLangCode: "zh",
			LangCode:       "zh",
		},
	})
}

// signedIn runs fn with the API of a signed-in session. Without a saved
// session it does not connect at all.
func signedIn(ctx context.Context, store Store, fn func(context.Context, *tg.Client) error) error {
	if !store.SignedIn() {
		return errSignedOut
	}
	app, err := store.App()
	if err != nil {
		return fmt.Errorf("读不到 Telegram API 凭据，请重新运行「扫码登录」：%w", err)
	}
	client := newClient(store, app, nil)
	err = client.Run(ctx, func(ctx context.Context) error { return fn(ctx, client.API()) })
	if auth.IsUnauthorized(err) {
		return errSignedOut
	}
	return err
}

// listChats reads the dialog list and remembers how to reach each chat.
func listChats(ctx context.Context, store Store) ([]Chat, error) {
	chats := []Chat{}
	peers, err := store.Peers()
	if err != nil {
		return nil, err
	}
	err = signedIn(ctx, store, func(ctx context.Context, api *tg.Client) error {
		iter := dialogs.NewQueryBuilder(api).GetDialogs().BatchSize(100).Iter()
		for len(chats) < maxChats && iter.Next(ctx) {
			elem := iter.Value()
			p, ok := peerOf(elem.Peer)
			if !ok {
				continue
			}
			chat, ok := chatOf(p, elem.Entities, elem.Dialog, elem.Last)
			if !ok {
				continue
			}
			peers[chat.ID] = p
			chats = append(chats, chat)
		}
		return iter.Err()
	})
	if err != nil {
		return nil, err
	}
	return chats, store.SavePeers(peers)
}

// history reads a chat's latest messages. Reading never marks them read.
func history(ctx context.Context, store Store, chatID string, limit int) ([]Message, error) {
	if _, _, err := parseChatID(chatID); err != nil {
		return nil, err
	}
	peers, err := store.Peers()
	if err != nil {
		return nil, err
	}
	p, known := peers[chatID]
	if !known {
		// A chat newer than the saved list: list again to learn it.
		if _, err := listChats(ctx, store); err != nil {
			return nil, err
		}
		if peers, err = store.Peers(); err != nil {
			return nil, err
		}
		if p, known = peers[chatID]; !known {
			return nil, fmt.Errorf("会话列表里没有 %s", chatID)
		}
	}
	var out []Message
	err = signedIn(ctx, store, func(ctx context.Context, api *tg.Client) error {
		result, err := api.MessagesGetHistory(ctx, &tg.MessagesGetHistoryRequest{Peer: p.input(), Limit: limit})
		if err != nil {
			return err
		}
		page, ok := result.AsModified()
		if !ok {
			return fmt.Errorf("没有拿到消息：%T", result)
		}
		out = messagesOf(page.GetMessages(), newNames(page.GetUsers(), page.GetChats()))
		return nil
	})
	return out, err
}
