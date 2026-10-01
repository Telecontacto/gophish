package config

import (
	"encoding/json"
	"io/ioutil"
	"os"
	"testing"

	"bitbucket.org/liamstask/goose/lib/goose"
	"github.com/go-sql-driver/mysql"
)

func TestLoadMySQLConfig(t *testing.T) {
	const dsn = "smoke:synthetic-password@tcp(mysql.railway.internal:3306)/gophish?charset=utf8mb4&parseTime=true&loc=UTC"
	driverConfig, err := mysql.ParseDSN(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if !driverConfig.ParseTime || driverConfig.DBName != "gophish" || driverConfig.Loc.String() != "UTC" {
		t.Fatal("documented MySQL DSN must parse datetime values in UTC")
	}
	input := &Config{
		DBName:         "mysql",
		DBPath:         dsn,
		DBSSLCaPath:    "/data/mysql-ca.pem",
		MigrationsPath: "../db/db_",
	}
	data, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	f, err := ioutil.TempFile("", "gophish-mysql-config")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(f.Name())
	if _, err := f.Write(data); err != nil {
		f.Close()
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	conf, err := LoadConfig(f.Name())
	if err != nil {
		t.Fatal(err)
	}
	if conf.DBName != "mysql" || conf.DBPath != dsn || conf.DBSSLCaPath != input.DBSSLCaPath || conf.MigrationsPath != "../db/db_mysql" {
		t.Fatal("MySQL connection, CA path or migration selection changed")
	}
	version, err := goose.GetMostRecentDBVersion(conf.MigrationsPath)
	if err != nil || version <= 0 {
		t.Fatalf("MySQL migrations not found: version=%d err=%v", version, err)
	}
}
