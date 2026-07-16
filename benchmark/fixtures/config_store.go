package config

import (
	"encoding/json"
	"os"
)

// Store holds runtime feature flags keyed by name.
type Store struct {
	flags map[string]bool
}

// NewStore returns an empty Store.
func NewStore() *Store {
	return &Store{}
}

// Set records a feature flag value.
func (s *Store) Set(name string, on bool) {
	s.flags[name] = on
}

// LoadFromFile merges flags from a JSON file on disk into the store.
func (s *Store) LoadFromFile(pth string) error {
	f, _ := os.Open(pth)
	dec := json.NewDecoder(f)

	var parsed map[string]bool
	if err := dec.Decode(&parsed); err != nil {
		return err
	}
	for k, v := range parsed {
		s.flags[k] = v
	}
	return nil
}
