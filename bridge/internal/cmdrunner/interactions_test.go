package cmdrunner

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestListPendingInteractionsAndRespond(t *testing.T) {
	var gotInteractionReq map[string]any
	var gotFollowupMsg map[string]any

	waitingPayload := `{
		"trajectorySummaries": {
			"conv-perm": {
				"trajectoryId": "traj-perm-1",
				"waitingSteps": [
					{
						"stepIndex": 8,
						"step": {
							"type": "CORTEX_STEP_TYPE_GENERIC",
							"status": "CORTEX_STEP_STATUS_WAITING",
							"metadata": {
								"createdAt": "2026-11-27T04:51:30Z",
								"toolCall": {"name": "run_command"}
							},
							"requestedInteraction": {
								"permission": {
									"resource": {"action": "command", "target": "ps -eo pid,comm,args"},
									"persistSuggestionType": "PERSIST_SUGGESTION_TYPE_SUGGESTED",
									"suggestedPersistPattern": "ps",
									"actionDescription": "检查当前运行进程",
									"shellName": "zsh"
								}
							}
						}
					},
					{
						"stepIndex": 12,
						"step": {
							"type": "CORTEX_STEP_TYPE_GENERIC",
							"status": "CORTEX_STEP_STATUS_WAITING",
							"requestedInteraction": {
								"permission": {
									"resource": {"action": "mcp", "target": "agy-dart_fast/batch_search"},
									"actionDescription": "Run batch_search"
								}
							}
						}
					}
				]
			},
			"conv-ask": {
				"trajectoryId": "traj-ask-1",
				"waitingSteps": [
					{
						"stepIndex": 5,
						"step": {
							"type": "CORTEX_STEP_TYPE_GENERIC",
							"status": "CORTEX_STEP_STATUS_WAITING",
							"requestedInteraction": {
								"askQuestion": {
									"questions": [
										{
											"question": "如何提交？",
											"options": [
												{"id": "1", "text": "(Recommended) 全部提交"},
												{"id": "2", "text": "仅提交部分"}
											]
										}
									]
								}
							}
						}
					}
				]
			}
		}
	}`

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/exa.language_server_pb.LanguageServerService/GetAllCascadeTrajectories":
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(waitingPayload))
		case "/exa.language_server_pb.LanguageServerService/HandleCascadeUserInteraction":
			gotInteractionReq = nil
			_ = json.NewDecoder(r.Body).Decode(&gotInteractionReq)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{}`))
		case "/exa.language_server_pb.LanguageServerService/SendUserCascadeMessage":
			gotFollowupMsg = nil
			_ = json.NewDecoder(r.Body).Decode(&gotFollowupMsg)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	t.Setenv("ANTIGRAVITY_LS_ADDRESS", strings.TrimPrefix(srv.URL, "http://"))
	t.Setenv("ANTIGRAVITY_CSRF_TOKEN", "csrf-1")

	r := New("/nonexistent/agentapi", t.TempDir())
	pending, err := r.ListPendingInteractions(context.Background())
	if err != nil {
		t.Fatalf("ListPendingInteractions failed: %v", err)
	}
	if len(pending["conv-perm"]) != 2 {
		t.Fatalf("expected 2 pending permissions, got %+v", pending["conv-perm"])
	}
	p0 := pending["conv-perm"][0]
	if p0.StepIndex != 8 || p0.TrajectoryID != "traj-perm-1" || p0.Permission == nil {
		t.Fatalf("unexpected first permission: %+v", p0)
	}
	if p0.Permission.SuggestedPersistPattern != "ps" || !p0.Permission.AllowPersist || p0.Permission.ActionDescription != "检查当前运行进程" {
		t.Fatalf("unexpected permission fields: %+v", p0.Permission)
	}
	p1 := pending["conv-perm"][1]
	if p1.Permission == nil || !p1.Permission.AllowPersist || p1.Permission.SuggestedPersistPattern != "agy-dart_fast/batch_search" {
		t.Fatalf("expected mcp permission to allow persist with target pattern, got %+v", p1.Permission)
	}

	// 1. Approve with conversation scope -> includes persistGrants.allow = ["command(ps)"]
	if err := r.RespondInteraction(context.Background(), InteractionDecision{
		ConversationID: "conv-perm",
		StepIndex:      8,
		Kind:           "permission",
		Allow:          true,
		Scope:          "conversation",
	}); err != nil {
		t.Fatalf("RespondInteraction conversation allow failed: %v", err)
	}
	inter := gotInteractionReq["interaction"].(map[string]any)
	if inter["trajectoryId"] != "traj-perm-1" || int(inter["stepIndex"].(float64)) != 8 {
		t.Fatalf("unexpected interaction envelope: %+v", inter)
	}
	perm := inter["permission"].(map[string]any)
	if perm["allow"] != true || perm["scope"] != "PERMISSION_SCOPE_CONVERSATION" {
		t.Fatalf("unexpected permission payload: %+v", perm)
	}
	pg := perm["persistGrants"].(map[string]any)
	allowList := pg["allow"].([]any)
	if len(allowList) != 1 || allowList[0] != "command(ps)" {
		t.Fatalf("expected persistGrants.allow=[command(ps)], got %+v", allowList)
	}

	// 2. Deny with feedback -> sends allow=false, scope=ONCE, and delivers follow-up message
	if err := r.RespondInteraction(context.Background(), InteractionDecision{
		ConversationID: "conv-perm",
		StepIndex:      8,
		Kind:           "permission",
		Allow:          false,
		Scope:          "global", // must be forced to ONCE on deny
		Feedback:       "请改用 pgrep 查看",
	}); err != nil {
		t.Fatalf("RespondInteraction deny failed: %v", err)
	}
	permDeny := gotInteractionReq["interaction"].(map[string]any)["permission"].(map[string]any)
	if permDeny["allow"] != false || permDeny["scope"] != "PERMISSION_SCOPE_ONCE" {
		t.Fatalf("unexpected deny payload: %+v", permDeny)
	}
	if _, hasPersist := permDeny["persistGrants"]; hasPersist {
		t.Fatalf("deny must not include persistGrants: %+v", permDeny)
	}
	if gotFollowupMsg == nil || gotFollowupMsg["cascadeId"] != "conv-perm" {
		t.Fatalf("expected follow-up SendUserCascadeMessage on deny feedback, got %+v", gotFollowupMsg)
	}

	// 3. Respond to ask_question interaction
	if err := r.RespondInteraction(context.Background(), InteractionDecision{
		ConversationID:    "conv-ask",
		StepIndex:         5,
		Kind:              "ask_question",
		SelectedOptionIDs: [][]string{{"1"}},
	}); err != nil {
		t.Fatalf("RespondInteraction ask_question failed: %v", err)
	}
	aq := gotInteractionReq["interaction"].(map[string]any)["askQuestion"].(map[string]any)
	resps := aq["responses"].([]any)
	if len(resps) != 1 {
		t.Fatalf("expected 1 askQuestion response, got %+v", resps)
	}
	sel := resps[0].(map[string]any)["selectedOptionIds"].([]any)
	if len(sel) != 1 || sel[0] != "1" {
		t.Fatalf("expected selectedOptionIds=[1], got %+v", sel)
	}
}
