package cmd

import "testing"

func TestMachineLabel(t *testing.T) {
	cases := []struct {
		name string
		in   any
		want string
	}{
		{"machine_name", map[string]any{"machine_name": "fountain-ab-x", "sprite_name": "fountain-ab-x", "status": "ready"}, "fountain-ab-x (ready)"},
		{"an older server's sprite_name", map[string]any{"sprite_name": "fountain-ab-y", "status": "suspended"}, "fountain-ab-y (suspended)"},
		{"no name", map[string]any{"status": "ready"}, "—"},
		{"no sandbox", nil, "—"},
	}
	for _, c := range cases {
		if got := machineLabel(c.in); got != c.want {
			t.Errorf("%s: machineLabel = %q, want %q", c.name, got, c.want)
		}
	}
}
