package cmdrunner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

// PermissionRequest describes a pending Antigravity tool/command/file/MCP permission prompt.
type PermissionRequest struct {
	Action                  string `json:"action"`
	Target                  string `json:"target"`
	ActionDescription       string `json:"actionDescription,omitempty"`
	Reason                  string `json:"reason,omitempty"`
	SuggestedPersistPattern string `json:"suggestedPersistPattern,omitempty"`
	AllowPersist            bool   `json:"allowPersist"`
	ShellName               string `json:"shellName,omitempty"`
}

// AskQuestionOption represents a selectable option in an ask_question interaction.
type AskQuestionOption struct {
	ID   string `json:"id"`
	Text string `json:"text"`
}

// AskQuestionItem represents a single prompt inside an ask_question interaction.
type AskQuestionItem struct {
	Question    string              `json:"question"`
	Options     []AskQuestionOption `json:"options"`
	MultiSelect bool                `json:"multiSelect,omitempty"`
}

// AskQuestionRequest describes a pending ask_question interaction waiting for user selection.
type AskQuestionRequest struct {
	Questions []AskQuestionItem `json:"questions"`
}

// PendingInteraction represents a live WAITING step requiring user authorization or answer.
type PendingInteraction struct {
	ConversationID string              `json:"conversationId"`
	TrajectoryID   string              `json:"trajectoryId"`
	StepIndex      int                 `json:"stepIndex"`
	Kind           string              `json:"kind"` // "permission" | "ask_question"
	ToolName       string              `json:"toolName,omitempty"`
	CreatedAtUnix  int64               `json:"createdAtUnix,omitempty"`
	Permission     *PermissionRequest  `json:"permission,omitempty"`
	AskQuestion    *AskQuestionRequest `json:"askQuestion,omitempty"`
}

// InteractionDecision carries a mobile client's response to a PendingInteraction.
type InteractionDecision struct {
	ConversationID    string     `json:"conversationId"`
	TrajectoryID      string     `json:"trajectoryId,omitempty"`
	StepIndex         int        `json:"stepIndex"`
	Kind              string     `json:"kind"` // "permission" | "ask_question"
	Allow             bool       `json:"allow"`
	Scope             string     `json:"scope,omitempty"` // "once" | "conversation" | "global"
	Action            string     `json:"action,omitempty"`
	Target            string     `json:"target,omitempty"`
	Feedback          string     `json:"feedback,omitempty"`
	SelectedOptionIDs [][]string `json:"selectedOptionIds,omitempty"`
}

type getAllCascadeTrajectoriesResp struct {
	TrajectorySummaries map[string]lsTrajectorySummary `json:"trajectorySummaries"`
}

type lsTrajectorySummary struct {
	TrajectoryID string          `json:"trajectoryId"`
	WaitingSteps []lsWaitingStep `json:"waitingSteps"`
}

type lsWaitingStep struct {
	StepIndex int         `json:"stepIndex"`
	Step      lsStepEntry `json:"step"`
}

type lsStepEntry struct {
	Type                 string                  `json:"type"`
	Status               string                  `json:"status"`
	Metadata             *lsStepMetadata         `json:"metadata"`
	RequestedInteraction *lsRequestedInteraction `json:"requestedInteraction"`
}

type lsStepMetadata struct {
	CreatedAt string `json:"createdAt"`
	ToolCall  *struct {
		Name string `json:"name"`
	} `json:"toolCall"`
}

type lsRequestedInteraction struct {
	Permission  *lsPermissionInteractionReq  `json:"permission"`
	AskQuestion *lsAskQuestionInteractionReq `json:"askQuestion"`
}

type lsPermissionInteractionReq struct {
	Resource *struct {
		Action string `json:"action"`
		Target string `json:"target"`
	} `json:"resource"`
	PersistSuggestionType   string `json:"persistSuggestionType"`
	SuggestedPersistPattern string `json:"suggestedPersistPattern"`
	ActionDescription       string `json:"actionDescription"`
	Reason                  string `json:"reason"`
	ShellName               string `json:"shellName"`
}

type lsAskQuestionInteractionReq struct {
	Questions []struct {
		Question    string `json:"question"`
		MultiSelect bool   `json:"multiSelect"`
		Options     []struct {
			ID   string `json:"id"`
			Text string `json:"text"`
		} `json:"options"`
	} `json:"questions"`
}

// ListPendingInteractions queries local Antigravity LanguageServerService for all
// currently WAITING permission / ask_question steps across conversations.
func (r *Runner) ListPendingInteractions(ctx context.Context) (map[string][]PendingInteraction, error) {
	addr, csrf, err := r.discoverEndpoint()
	if err != nil {
		return nil, err
	}

	endpoint := buildLSEndpoint(addr, "GetAllCascadeTrajectories")
	runCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(runCtx, http.MethodPost, endpoint, bytes.NewReader([]byte("{}")))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connect-Protocol-Version", "1")
	if csrf != "" {
		req.Header.Set("x-codeium-csrf-token", csrf)
	}

	resp, err := r.getHTTPClient().Do(req)
	if err != nil {
		return nil, fmt.Errorf("GetAllCascadeTrajectories request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("GetAllCascadeTrajectories HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var parsed getAllCascadeTrajectoriesResp
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, fmt.Errorf("decode GetAllCascadeTrajectories: %w", err)
	}

	out := make(map[string][]PendingInteraction)
	for convID, summary := range parsed.TrajectorySummaries {
		if len(summary.WaitingSteps) == 0 {
			continue
		}
		var list []PendingInteraction
		for _, ws := range summary.WaitingSteps {
			item, ok := convertWaitingStep(convID, summary.TrajectoryID, ws)
			if ok {
				list = append(list, item)
			}
		}
		if len(list) > 0 {
			sort.Slice(list, func(i, j int) bool {
				return list[i].StepIndex < list[j].StepIndex
			})
			out[convID] = list
		}
	}
	return out, nil
}

// RespondInteraction submits an approval, denial, or ask_question answer to Antigravity's
// LanguageServerService/HandleCascadeUserInteraction RPC.
func (r *Runner) RespondInteraction(ctx context.Context, dec InteractionDecision) error {
	dec.ConversationID = strings.TrimSpace(dec.ConversationID)
	dec.TrajectoryID = strings.TrimSpace(dec.TrajectoryID)
	dec.Kind = strings.TrimSpace(dec.Kind)
	if dec.ConversationID == "" {
		return errors.New("conversationId is required")
	}
	if dec.StepIndex < 0 {
		return errors.New("stepIndex must be non-negative")
	}
	if dec.Kind != "permission" && dec.Kind != "ask_question" {
		return fmt.Errorf("unsupported interaction kind: %s", dec.Kind)
	}

	addr, csrf, err := r.discoverEndpoint()
	if err != nil {
		return err
	}

	// Best-effort lookup of the authoritative live waiting step so trajectoryId and
	// persistGrants always match what Antigravity actually requested.
	var liveMatch *PendingInteraction
	if allPending, err := r.ListPendingInteractions(ctx); err == nil {
		for i := range allPending[dec.ConversationID] {
			item := allPending[dec.ConversationID][i]
			if item.StepIndex == dec.StepIndex {
				liveMatch = &item
				break
			}
		}
	}

	trajectoryID := dec.TrajectoryID
	if liveMatch != nil && liveMatch.TrajectoryID != "" {
		trajectoryID = liveMatch.TrajectoryID
	}
	if trajectoryID == "" {
		return errors.New("trajectoryId is required and no live waiting step matched")
	}

	interactionBody := map[string]any{
		"trajectoryId": trajectoryID,
		"stepIndex":    dec.StepIndex,
	}

	switch dec.Kind {
	case "permission":
		scope := normalizePermissionScope(dec.Scope, dec.Allow)
		permBody := map[string]any{
			"scope": scope,
		}
		if dec.Allow {
			permBody["allow"] = true
			if scope == "PERMISSION_SCOPE_CONVERSATION" || scope == "PERMISSION_SCOPE_GLOBAL" {
				action := strings.TrimSpace(dec.Action)
				pattern := strings.TrimSpace(dec.Target)
				if liveMatch != nil && liveMatch.Permission != nil {
					if liveMatch.Permission.Action != "" {
						action = liveMatch.Permission.Action
					}
					if liveMatch.Permission.SuggestedPersistPattern != "" {
						pattern = liveMatch.Permission.SuggestedPersistPattern
					} else if liveMatch.Permission.Target != "" {
						pattern = liveMatch.Permission.Target
					}
				}
				if grant := BuildPersistGrant(action, pattern); grant != "" {
					permBody["persistGrants"] = map[string]any{
						"allow": []string{grant},
					}
				}
			}
		} else {
			permBody["allow"] = false
		}
		interactionBody["permission"] = permBody

	case "ask_question":
		if liveMatch == nil || liveMatch.AskQuestion == nil || len(liveMatch.AskQuestion.Questions) == 0 {
			return errors.New("no live ask_question waiting step matched")
		}
		responses := make([]map[string]any, 0, len(liveMatch.AskQuestion.Questions))
		for i, q := range liveMatch.AskQuestion.Questions {
			var selected []string
			if i < len(dec.SelectedOptionIDs) {
				selected = dec.SelectedOptionIDs[i]
			}
			opts := make([]map[string]string, 0, len(q.Options))
			for _, o := range q.Options {
				opts = append(opts, map[string]string{
					"id":   o.ID,
					"text": o.Text,
				})
			}
			responses = append(responses, map[string]any{
				"question":          q.Question,
				"options":           opts,
				"selectedOptionIds": selected,
			})
		}
		interactionBody["askQuestion"] = map[string]any{
			"responses": responses,
		}
	}

	payload, err := json.Marshal(map[string]any{
		"cascadeId":   dec.ConversationID,
		"interaction": interactionBody,
	})
	if err != nil {
		return err
	}

	endpoint := buildLSEndpoint(addr, "HandleCascadeUserInteraction")
	runCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(runCtx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connect-Protocol-Version", "1")
	if csrf != "" {
		req.Header.Set("x-codeium-csrf-token", csrf)
	}

	resp, err := r.getHTTPClient().Do(req)
	if err != nil {
		return fmt.Errorf("HandleCascadeUserInteraction request failed: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HandleCascadeUserInteraction HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	// If the user denied permission and provided alternative instructions ("tell the agent what to do instead"),
	// deliver the follow-up message immediately after unlocking the waiting step.
	if dec.Kind == "permission" && !dec.Allow {
		if feedback := strings.TrimSpace(dec.Feedback); feedback != "" {
			_, _ = r.SendMessage(ctx, dec.ConversationID, feedback)
		}
	}
	return nil
}

// BuildPersistGrant formats a permission grant string like "command(ps)" or "mcp(srv/tool)".
func BuildPersistGrant(action, pattern string) string {
	action = strings.TrimSpace(action)
	pattern = strings.TrimSpace(pattern)
	if action == "" || pattern == "" {
		return ""
	}
	return fmt.Sprintf("%s(%s)", action, pattern)
}

func normalizePermissionScope(raw string, allow bool) string {
	if !allow {
		return "PERMISSION_SCOPE_ONCE"
	}
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "conversation", "permission_scope_conversation":
		return "PERMISSION_SCOPE_CONVERSATION"
	case "global", "permission_scope_global":
		return "PERMISSION_SCOPE_GLOBAL"
	default:
		return "PERMISSION_SCOPE_ONCE"
	}
}

func convertWaitingStep(convID, trajectoryID string, ws lsWaitingStep) (PendingInteraction, bool) {
	if ws.Step.RequestedInteraction == nil {
		return PendingInteraction{}, false
	}
	if ws.Step.Status != "" && ws.Step.Status != "CORTEX_STEP_STATUS_WAITING" {
		return PendingInteraction{}, false
	}

	item := PendingInteraction{
		ConversationID: convID,
		TrajectoryID:   trajectoryID,
		StepIndex:      ws.StepIndex,
	}
	if ws.Step.Metadata != nil {
		if ws.Step.Metadata.ToolCall != nil {
			item.ToolName = strings.TrimSpace(ws.Step.Metadata.ToolCall.Name)
		}
		if ws.Step.Metadata.CreatedAt != "" {
			if t, err := time.Parse(time.RFC3339Nano, ws.Step.Metadata.CreatedAt); err == nil {
				item.CreatedAtUnix = t.Unix()
			} else if t, err := time.Parse(time.RFC3339, ws.Step.Metadata.CreatedAt); err == nil {
				item.CreatedAtUnix = t.Unix()
			}
		}
	}

	if perm := ws.Step.RequestedInteraction.Permission; perm != nil {
		action := ""
		target := ""
		if perm.Resource != nil {
			action = strings.TrimSpace(perm.Resource.Action)
			target = strings.TrimSpace(perm.Resource.Target)
		}
		pattern := strings.TrimSpace(perm.SuggestedPersistPattern)
		allowPersist := false
		if !strings.Contains(strings.ToUpper(perm.PersistSuggestionType), "DISALLOWED") {
			if pattern != "" {
				allowPersist = true
			} else if action != "" && target != "" && action != "command" {
				pattern = target
				allowPersist = true
			}
		}
		item.Kind = "permission"
		item.Permission = &PermissionRequest{
			Action:                  action,
			Target:                  target,
			ActionDescription:       strings.TrimSpace(perm.ActionDescription),
			Reason:                  strings.TrimSpace(perm.Reason),
			SuggestedPersistPattern: pattern,
			AllowPersist:            allowPersist,
			ShellName:               strings.TrimSpace(perm.ShellName),
		}
		return item, true
	}

	if aq := ws.Step.RequestedInteraction.AskQuestion; aq != nil && len(aq.Questions) > 0 {
		qs := make([]AskQuestionItem, 0, len(aq.Questions))
		for _, q := range aq.Questions {
			opts := make([]AskQuestionOption, 0, len(q.Options))
			for _, o := range q.Options {
				opts = append(opts, AskQuestionOption{
					ID:   strings.TrimSpace(o.ID),
					Text: strings.TrimSpace(o.Text),
				})
			}
			qs = append(qs, AskQuestionItem{
				Question:    strings.TrimSpace(q.Question),
				Options:     opts,
				MultiSelect: q.MultiSelect,
			})
		}
		item.Kind = "ask_question"
		item.AskQuestion = &AskQuestionRequest{Questions: qs}
		return item, true
	}

	return PendingInteraction{}, false
}

func buildLSEndpoint(addr, method string) string {
	baseURL := strings.TrimSpace(addr)
	if !strings.HasPrefix(baseURL, "http://") && !strings.HasPrefix(baseURL, "https://") {
		baseURL = "http://" + baseURL
	}
	return strings.TrimRight(baseURL, "/") + "/exa.language_server_pb.LanguageServerService/" + method
}

func (r *Runner) getHTTPClient() *http.Client {
	if r.httpClient != nil {
		return r.httpClient
	}
	return &http.Client{
		Timeout:   25 * time.Second,
		Transport: &http.Transport{Proxy: nil},
	}
}
