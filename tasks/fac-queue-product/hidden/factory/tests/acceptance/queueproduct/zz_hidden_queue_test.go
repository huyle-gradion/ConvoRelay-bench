package queueproduct_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/huyle-gradion/turbo-12f/internal/queue"
)

// host starts every task it is asked for and remembers which.
type host struct{ prepared []string }

func (h *host) IsAncestor(commit, ref string) bool { return false }

func (h *host) Prepare(home, taskPath string) (bool, string, error) {
	h.prepared = append(h.prepared, strings.TrimSuffix(filepath.Base(taskPath), ".json"))
	return true, "", nil
}

func writeJSON(t *testing.T, path string, v map[string]any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(v)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

// pass runs one queue pass over a state home that holds runs and a queue folder that holds tasks, and
// returns the tasks it started and what it printed. Each run and task is a JSON object.
func pass(t *testing.T, runs, tasks []map[string]any) (started []string, out string) {
	t.Helper()
	home, dir := filepath.Join(t.TempDir(), "home"), filepath.Join(t.TempDir(), "queue")
	for _, r := range runs {
		r["phase"] = "tdd"
		r["base"] = "main"
		writeJSON(t, filepath.Join(home, "runs", r["task_id"].(string)+".json"), r)
	}
	if len(runs) == 0 {
		if err := os.MkdirAll(filepath.Join(home, "runs"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, task := range tasks {
		writeJSON(t, filepath.Join(dir, task["id"].(string)+".json"), task)
	}
	loadedRuns, err := queue.LoadRuns(home)
	if err != nil {
		t.Fatal(err)
	}
	loadedTasks, err := queue.LoadTasks(dir)
	if err != nil {
		t.Fatal(err)
	}
	h := &host{}
	var buf bytes.Buffer
	if err := queue.Admit(h, home, loadedRuns, loadedTasks, 10, &buf); err != nil {
		t.Fatal(err)
	}
	return h.prepared, buf.String()
}

func alphaRun() map[string]any { return map[string]any{"task_id": "run-a", "product": "alpha"} }

func TestHiddenATaskOfAnotherProductStartsBesideARunWithNoTouches(t *testing.T) {
	started, out := pass(t, []map[string]any{alphaRun()}, []map[string]any{
		{"id": "beta-1", "product": "beta"},
		{"id": "alpha-1", "product": "alpha"},
		{"id": "plain-1"},
	})
	if want := []string{"beta-1"}; !slices.Equal(started, want) {
		t.Errorf("started %v, want %v: only the task of the other product may start\n%s", started, want, out)
	}
}

func TestHiddenTwoQueuedTasksOfDifferentProductsStartTogether(t *testing.T) {
	started, out := pass(t, nil, []map[string]any{
		{"id": "alpha-1", "product": "alpha"},
		{"id": "beta-1", "product": "beta"},
	})
	if want := []string{"alpha-1", "beta-1"}; !slices.Equal(started, want) {
		t.Errorf("started %v, want %v\n%s", started, want, out)
	}
}

func TestHiddenATaskWithTouchesOfAnotherProductStartsBesideARunWithNone(t *testing.T) {
	started, out := pass(t, []map[string]any{alphaRun()}, []map[string]any{
		{"id": "beta-1", "product": "beta", "touches": []string{"src/x"}},
	})
	if want := []string{"beta-1"}; !slices.Equal(started, want) {
		t.Errorf("started %v, want %v\n%s", started, want, out)
	}
}
