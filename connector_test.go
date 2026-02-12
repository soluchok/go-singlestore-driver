package mysql

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestConnectorReturnsTimeout(t *testing.T) {
	connector := newConnector(&Config{
		Net:     "tcp",
		Addr:    "1.1.1.1:1234",
		Timeout: 10 * time.Millisecond,
	})

	_, err := connector.Connect(context.Background())
	if err == nil {
		t.Fatal("error expected")
	}

	if nerr, ok := err.(*net.OpError); ok {
		expected := "dial tcp 1.1.1.1:1234: i/o timeout"
		if nerr.Error() != expected {
			t.Fatalf("expected %q, got %q", expected, nerr.Error())
		}
	} else {
		t.Fatalf("expected %T, got %T", nerr, err)
	}
}

func TestDisableFetchConnectionInfo(t *testing.T) {
	ctx := context.Background()

	if isFetchConnectionInfoDisabled(ctx) {
		t.Fatal("expected fetch connection info to be enabled")
	}

	// disable fetch connection info
	ctx = disableFetchConnectionInfo(ctx)

	if !isFetchConnectionInfoDisabled(ctx) {
		t.Fatal("expected fetch connection info to be disabled")
	}

	// verify that using a different struct{} value doesn't work
	ctx = context.WithValue(context.Background(), struct{}{}, struct{}{})
	if isFetchConnectionInfoDisabled(ctx) {
		t.Fatal("external code should not be able to disable fetch connection info")
	}
}
