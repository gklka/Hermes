package main

import (
	"context"
	"errors"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// MARK: - Polls
//
// A group chat's poll arrives as a message whose card (an XMA with an "xma_poll_details_card"
// button) shows the question and the first three options. The options and the votes come in
// their own tables (LSAddPollOption, LSAddPollVote, and LSAddPollForThread when the poll
// changes, pointing at the system message saying so). Messenger's web app works the same way.

// Like Messenger's web app (MessengerWebPollConstants).
const (
	pollMaxQuestionLength = 200
	pollMaxOptionLength   = 140
	pollMinOptions        = 2
	pollMaxOptions        = 10
)

// setCardVoters takes who voted from a poll's card: every change to a poll comes with a new
// one, listing up to three options with their voters (their pictures' fallback addresses have
// their IDs). Only a card newer than the last one used counts.
func (c *Core) setCardVoters(pollID string, x *table.WrappedXMA, cs *changeSet) {
	key := kvPollVoters + pollID
	if last, _ := strconv.ParseInt(c.store.Get(key), 10, 64); x.TimestampMs <= last {
		return
	}
	items := []struct {
		id        int64
		fallbacks string
		count     int64
	}{
		{x.ListItemId1, x.ListItemContactUrlFallbackList1, x.ListItemTotalCount1},
		{x.ListItemId2, x.ListItemContactUrlFallbackList2, x.ListItemTotalCount2},
		{x.ListItemId3, x.ListItemContactUrlFallbackList3, x.ListItemTotalCount3},
	}
	for _, item := range items {
		if item.id == 0 {
			continue
		}
		voters := voterIDs(item.fallbacks)
		// Unless the card lists them all (it may not, for many), its voters are kept as they are.
		if int64(len(voters)) != item.count {
			continue
		}
		c.store.SetOptionVoters(pollID, id64(item.id), voters, x.TimestampMs)
	}
	c.store.Set(key, strconv.FormatInt(x.TimestampMs, 10))
	c.pollChanged(pollID, cs)
}

// voterIDs reads the people from a card's picture fallbacks ("/messaging/lightspeed/
// media_fallback/?entity_id=100000000000001&…", joined with ", ").
func voterIDs(fallbacks string) []string {
	var ids []string
	for _, part := range strings.Split(fallbacks, ", ") {
		if u, err := url.Parse(strings.TrimSpace(part)); err == nil {
			if id := u.Query().Get("entity_id"); id != "" {
				ids = append(ids, id)
			}
		}
	}
	return ids
}

// pollFromXMA reads a poll's card: its ID is the button's target.
func pollFromXMA(x *table.WrappedXMA) *apiPoll {
	if x.CTA == nil || !strings.HasPrefix(x.CTA.Type_, "xma_poll_") {
		return nil
	}
	id := x.CTA.TargetId
	if id == 0 {
		id = x.TargetId
	}
	if id == 0 {
		id, _ = strconv.ParseInt(x.AttachmentFbid, 10, 64)
	}
	if id == 0 {
		return nil
	}
	poll := &apiPoll{
		ID:          id64(id),
		Question:    firstNonEmpty(x.ListItemsDescriptionText, x.TitleText),
		ButtonTitle: x.CTA.Title,
		// "2 more options", in the user's language.
		MoreCount: leadingNumber(x.ListItemsSecondaryDescriptionText),
		Options:   []apiPollOption{},
	}
	items := []struct {
		id            int64
		text, avatars string
		percent       int64
		count         int64
	}{
		{x.ListItemId1, x.ListItemTitleText1, x.ListItemContactUrlList1, x.ListItemProgressBarFilledPercentage1, x.ListItemTotalCount1},
		{x.ListItemId2, x.ListItemTitleText2, x.ListItemContactUrlList2, x.ListItemProgressBarFilledPercentage2, x.ListItemTotalCount2},
		{x.ListItemId3, x.ListItemTitleText3, x.ListItemContactUrlList3, x.ListItemProgressBarFilledPercentage3, x.ListItemTotalCount3},
	}
	for _, item := range items {
		if item.text == "" {
			continue
		}
		option := apiPollOption{ID: id64(item.id), Text: item.text, VoteCount: int(item.count), Percent: int(item.percent), Voters: []apiParticipant{}}
		// The voters' pictures, joined with ", ".
		for _, url := range strings.Split(item.avatars, ", ") {
			if url = strings.TrimSpace(url); url != "" {
				option.Voters = append(option.Voters, apiParticipant{AvatarURL: url})
			}
		}
		poll.Options = append(poll.Options, option)
	}
	return poll
}

// hasPollCard: one of the attachments is a poll's card (not only a link to the poll).
func hasPollCard(attachments []storedAttachment) bool {
	return slices.ContainsFunc(attachments, func(a storedAttachment) bool {
		return a.Kind == kindPoll && a.Poll != nil && len(a.Poll.Options) > 0
	})
}

// leadingNumber is the first number in s ("2 more options" → 2), or 0.
func leadingNumber(s string) int {
	start := strings.IndexFunc(s, func(r rune) bool { return r >= '0' && r <= '9' })
	if start < 0 {
		return 0
	}
	end := start
	for end < len(s) && s[end] >= '0' && s[end] <= '9' {
		end++
	}
	n, _ := strconv.Atoi(s[start:end])
	return n
}

// handlePollTables stores polls' options and votes, and updates their cards.
func (c *Core) handlePollTables(tbl *table.LSTable, cs *changeSet) {
	options := slices.Concat(tbl.LSAddPollOption, tbl.LSAddPollOptionV2)
	votes := slices.Concat(tbl.LSAddPollVote, tbl.LSAddPollVoteV2)
	if len(tbl.LSAddPollForThread)+len(options)+len(votes) == 0 {
		return
	}
	c.log.Debug().Any("polls", tbl.LSAddPollForThread).Any("options", options).Any("votes", votes).Msg("Poll tables")

	// The polls that changed.
	changed := map[string]bool{}
	for _, p := range tbl.LSAddPollForThread {
		changed[id64(p.PollID)] = true
	}
	for _, o := range options {
		pollID := id64(o.PollID)
		c.store.PutPollOption(pollID, id64(o.OptionID), o.OptionText, o.SortKeyVotingTimestamp, o.SortKeyCreationTimestamp)
		changed[pollID] = true
	}
	// A vote row is one vote cast (only the option that changed, not the voter's whole choice).
	// Votes taken back don't come as rows: the poll's new card says who voted (setCardVoters).
	for _, v := range votes {
		pollID := id64(v.PollID)
		changed[pollID] = true
		c.store.AddPollVote(pollID, id64(v.OptionID), id64(v.ContactID), v.TimestampMS)
	}
	for pollID := range changed {
		c.pollChanged(pollID, cs)
	}
}

// setPollCard makes the message the one showing the poll, if it's its first (where it was
// created; changes to it come with new cards, which aren't shown).
func (c *Core) setPollCard(pollID, messageID string, timestamp int64, cs *changeSet) {
	previous := c.store.Get(kvPollCard + pollID)
	if previous == messageID {
		return
	}
	if previous != "" {
		if m := c.store.GetMessage(previous); m != nil {
			if m.Timestamp <= timestamp {
				return
			}
			cs.message(previous)
		}
	}
	c.store.Set(kvPollCard+pollID, messageID)
}

// pollChanged shows the poll's new votes and options.
func (c *Core) pollChanged(pollID string, cs *changeSet) {
	if messageID := c.store.Get(kvPollCard + pollID); messageID != "" {
		cs.message(messageID)
	}
}

// createPoll starts a poll in a group chat.
func (c *Core) createPoll(ctx context.Context, threadID, question string, options []string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	if t.Type.IsWhatsApp() {
		return errors.New("polls can't be created in encrypted chats")
	}
	question = strings.TrimSpace(question)
	var cleaned []string
	for _, o := range options {
		if o = strings.TrimSpace(o); o != "" && !slices.ContainsFunc(cleaned, func(c string) bool { return strings.EqualFold(c, o) }) {
			cleaned = append(cleaned, o)
		}
	}
	if question == "" || len(cleaned) < pollMinOptions {
		return errors.New("a poll needs a question and two different options")
	}
	cli, err := c.requireClient()
	if err != nil {
		return err
	}
	key, syncGroup := c.fbTaskTarget(t)
	resp, err := cli.ExecuteTasks(ctx, &socket.CreatePollTask{
		QuestionText: truncateRunes(question, pollMaxQuestionLength), ThreadKey: key,
		Options: limitOptions(cleaned), SyncGroup: syncGroup,
	})
	if err != nil {
		return err
	}
	c.handleTable(resp)
	return nil
}

func limitOptions(options []string) []string {
	if len(options) > pollMaxOptions {
		options = options[:pollMaxOptions]
	}
	for i, o := range options {
		options[i] = truncateRunes(o, pollMaxOptionLength)
	}
	return options
}

func truncateRunes(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}

// pollUpdateTask is the web app's vote (LSIssuePollUpdateForThread): every option you chose
// (selected), and options you add, each with whether you vote for it. (messagix's
// UpdatePollTask has the added options as numbers; the web app sends true/false.)
type pollUpdateTask struct {
	ThreadKey       int64             `json:"thread_key"`
	PollID          int64             `json:"poll_id"`
	AddedOptions    []map[string]bool `json:"added_options"`
	SelectedOptions []int64           `json:"selected_options"`
	SyncGroup       int64             `json:"sync_group"`
}

func (t *pollUpdateTask) GetLabel() string { return socket.TaskLabels["UpdatePollTask"] }

func (t *pollUpdateTask) Create() (any, string) { return t, "poll_update" }

// votePoll sends your choice in a poll: the options you vote for (all of them, not only the
// changes), and any you add.
func (c *Core) votePoll(ctx context.Context, threadID, pollID string, selected []string, added []apiNewPollOption) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	cli, err := c.requireClient()
	if err != nil {
		return err
	}
	pid, err := strconv.ParseInt(pollID, 10, 64)
	if err != nil {
		return errors.New("invalid poll")
	}
	task := &pollUpdateTask{PollID: pid, AddedOptions: []map[string]bool{}, SelectedOptions: []int64{}}
	task.ThreadKey, task.SyncGroup = c.fbTaskTarget(t)
	for _, id := range selected {
		if n, err := strconv.ParseInt(id, 10, 64); err == nil {
			task.SelectedOptions = append(task.SelectedOptions, n)
		}
	}
	for _, o := range added {
		if text := truncateRunes(strings.TrimSpace(o.Text), pollMaxOptionLength); text != "" {
			task.AddedOptions = append(task.AddedOptions, map[string]bool{text: o.Voted})
		}
	}
	resp, err := cli.ExecuteTasks(ctx, task)
	if err != nil {
		return err
	}
	c.handleTable(resp)
	// Your votes show at once (the sync confirms them; added options come with it).
	now := time.Now().UnixMilli()
	votes := map[string]int64{}
	for _, id := range selected {
		votes[id] = now
	}
	c.store.SetPollVotes(pollID, c.selfID(), votes)
	cs := newChangeSet()
	c.pollChanged(pollID, cs)
	c.flush(cs)
	return nil
}

// MARK: - Storage

type pollOptionRow struct {
	ID, Text             string
	VotingTS, CreationTS int64
	Voters               []string // most recent first
}

func (s *Store) PutPollOption(pollID, optionID, text string, votingTS, creationTS int64) {
	_, _ = s.db.Exec(`
		INSERT INTO poll_options (poll_id, option_id, text, voting_ts, creation_ts) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (poll_id, option_id) DO UPDATE SET
			text=CASE WHEN excluded.text<>'' THEN excluded.text ELSE poll_options.text END,
			voting_ts=excluded.voting_ts,
			creation_ts=CASE WHEN excluded.creation_ts<>0 THEN excluded.creation_ts ELSE poll_options.creation_ts END
	`, pollID, optionID, text, votingTS, creationTS)
}

// SetPollVotes replaces someone's votes in a poll (option → when).
func (s *Store) SetPollVotes(pollID, voterID string, votes map[string]int64) {
	_, _ = s.db.Exec(`DELETE FROM poll_votes WHERE poll_id=? AND voter_id=?`, pollID, voterID)
	for optionID, ts := range votes {
		_, _ = s.db.Exec(`INSERT OR REPLACE INTO poll_votes (poll_id, option_id, voter_id, timestamp) VALUES (?, ?, ?, ?)`,
			pollID, optionID, voterID, ts)
	}
}

// SetOptionVoters makes these the option's voters (keeping when the ones still there voted).
func (s *Store) SetOptionVoters(pollID, optionID string, voters []string, ts int64) {
	rows, err := s.db.Query(`SELECT voter_id FROM poll_votes WHERE poll_id=? AND option_id=?`, pollID, optionID)
	if err != nil {
		return
	}
	var gone []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil && !slices.Contains(voters, id) {
			gone = append(gone, id)
		}
	}
	rows.Close()
	for _, id := range gone {
		_, _ = s.db.Exec(`DELETE FROM poll_votes WHERE poll_id=? AND option_id=? AND voter_id=?`, pollID, optionID, id)
	}
	for _, id := range voters {
		_, _ = s.db.Exec(`INSERT OR IGNORE INTO poll_votes (poll_id, option_id, voter_id, timestamp) VALUES (?, ?, ?, ?)`,
			pollID, optionID, id, ts)
	}
}

func (s *Store) AddPollVote(pollID, optionID, voterID string, ts int64) {
	_, _ = s.db.Exec(`INSERT OR REPLACE INTO poll_votes (poll_id, option_id, voter_id, timestamp) VALUES (?, ?, ?, ?)`,
		pollID, optionID, voterID, ts)
}

func (s *Store) pollOptions(pollID string) []pollOptionRow {
	rows, err := s.db.Query(`SELECT option_id, text, voting_ts, creation_ts FROM poll_options WHERE poll_id=?`, pollID)
	if err != nil {
		return nil
	}
	var options []pollOptionRow
	for rows.Next() {
		var o pollOptionRow
		if rows.Scan(&o.ID, &o.Text, &o.VotingTS, &o.CreationTS) == nil {
			options = append(options, o)
		}
	}
	rows.Close()
	if len(options) == 0 {
		return nil
	}
	voters := map[string][]string{}
	rows, err = s.db.Query(`SELECT option_id, voter_id FROM poll_votes WHERE poll_id=? ORDER BY timestamp DESC`, pollID)
	if err == nil {
		for rows.Next() {
			var optionID, voterID string
			if rows.Scan(&optionID, &voterID) == nil {
				voters[optionID] = append(voters[optionID], voterID)
			}
		}
		rows.Close()
	}
	for i := range options {
		options[i].Voters = voters[options[i].ID]
	}
	return options
}

// completePoll fills in a poll's options from its synced votes (if there are any).
func (s *Store) completePoll(threadID string, poll *apiPoll, selfID string) {
	if poll.ID == "" {
		return
	}
	options := s.pollOptions(poll.ID)
	if options == nil {
		return
	}
	// In the order they were added, like Messages (the bubbles' widths show the votes).
	slices.SortStableFunc(options, func(a, b pollOptionRow) int {
		if d := compareInt64(a.CreationTS, b.CreationTS); d != 0 {
			return d
		}
		return strings.Compare(a.ID, b.ID)
	})
	people := map[string]apiParticipant{}
	for _, p := range s.Participants(threadID) {
		people[p.UserID] = apiParticipant{ID: p.UserID, Name: p.Name, AvatarURL: p.AvatarURL}
	}
	members := len(people)
	person := func(id string) apiParticipant {
		if p, ok := people[id]; ok {
			return p
		}
		p := apiParticipant{ID: id}
		_ = s.db.QueryRow(`SELECT name, avatar_url FROM contacts WHERE id=?`, id).Scan(&p.Name, &p.AvatarURL)
		people[id] = p
		return p
	}
	poll.Options = make([]apiPollOption, 0, len(options))
	for _, o := range options {
		option := apiPollOption{ID: o.ID, Text: o.Text, VoteCount: len(o.Voters), Voters: []apiParticipant{}}
		for _, id := range o.Voters {
			option.Voters = append(option.Voters, person(id))
			option.Voted = option.Voted || id == selfID
		}
		if members > 0 {
			option.Percent = min(100, option.VoteCount*100/members)
		}
		poll.Options = append(poll.Options, option)
	}
	poll.MoreCount = 0
	poll.IsComplete = true
}

func compareInt64(a, b int64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}
