//go:build !linux

package layers

import "context"

func Snapshot(context.Context, string, string, Limits) (Result, error) { return Result{}, ErrInvalid }
func Export(context.Context, string, string, string, string, Limits) (Result, error) {
	return Result{}, ErrInvalid
}
func ProcessSnapshot(string) (Result, error)   { return Result{}, ErrInvalid }
func Quiescent(string, string) (Result, error) { return Result{}, ErrInvalid }
