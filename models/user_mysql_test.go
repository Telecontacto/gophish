package models

import (
	"database/sql"
	"strings"
	"testing"
	"time"

	"github.com/jinzhu/gorm"
)

func TestMySQLUserUnsetLastLogin(t *testing.T) {
	// Exercise GORM's real MySQL INSERT/UPDATE generation without a network
	// server. SQLite executes that SQL with a CHECK rejecting invalid dates.
	storage, err := gorm.Open("sqlite3", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	storage.DB().SetMaxOpenConns(1)
	err = storage.Exec(`CREATE TABLE users (
		id INTEGER PRIMARY KEY, username TEXT, hash TEXT, api_key TEXT,
		role_id INTEGER, password_change_required BOOLEAN, account_locked BOOLEAN,
		last_login DATETIME DEFAULT NULL
		CHECK (last_login IS NULL OR last_login >= '1000-01-01')
	)`).Error
	if err != nil {
		t.Fatal(err)
	}
	mysqlDB, err := gorm.Open("mysql", storage.DB())
	if err != nil {
		t.Fatal(err)
	}
	user := User{Username: "bootstrap-admin", ApiKey: "synthetic-api-key", PasswordChangeRequired: true}
	if err := mysqlDB.Save(&user).Error; err != nil {
		t.Fatalf("creating a never-logged-in user failed: %v", err)
	}
	assertNull := func() {
		t.Helper()
		var stored sql.NullTime
		if err := storage.DB().QueryRow("SELECT last_login FROM users WHERE id = ?", user.Id).Scan(&stored); err != nil {
			t.Fatal(err)
		}
		if stored.Valid {
			t.Fatal("never-logged-in user must retain SQL NULL, not a zero or invented date")
		}
	}
	assertNull()

	// Startup immediately saves the generated password; an insert-only default
	// would not protect this update or subsequent pre-login account edits.
	user.Hash = "synthetic-password-hash"
	if err := mysqlDB.Save(&user).Error; err != nil {
		t.Fatalf("saving the bootstrap password failed: %v", err)
	}
	assertNull()
	var loaded User
	if err := mysqlDB.First(&loaded, user.Id).Error; err != nil {
		t.Fatal(err)
	}
	if !loaded.LastLogin.IsZero() || loaded.Hash != user.Hash || !loaded.PasswordChangeRequired {
		t.Fatal("loading SQL NULL must preserve unset login time and other user fields")
	}

	user.LastLogin = time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	if err := mysqlDB.Save(&user).Error; err != nil {
		t.Fatalf("saving a real login timestamp failed: %v", err)
	}
	if err := mysqlDB.First(&loaded, user.Id).Error; err != nil {
		t.Fatal(err)
	}
	if !loaded.LastLogin.Equal(user.LastLogin) {
		t.Fatal("real login timestamps must still be persisted")
	}

	// Keep the scope's caller-supplied omissions, and leave SQLite behavior alone.
	scope := mysqlDB.Omit("Hash").NewScope(&User{})
	if err := (&User{}).BeforeSave(scope); err != nil {
		t.Fatal(err)
	}
	if strings.Join(scope.OmitAttrs(), ",") != "Hash,last_login" {
		t.Fatal("existing omitted columns must be retained")
	}
	sqliteScope := storage.NewScope(&User{})
	if err := (&User{}).BeforeSave(sqliteScope); err != nil || len(sqliteScope.OmitAttrs()) != 0 {
		t.Fatal("SQLite save behavior must remain unchanged")
	}
}
