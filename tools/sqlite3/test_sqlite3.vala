void main () {
    c2vala_init_globals ();
    print (@"SQLite version: $(sqlite3_libversion ())\n");

    sqlite3?[] db_out = new sqlite3?[1];
    int rc = sqlite3_open (c_str_to_bytes (":memory:"), db_out);
    print (@"sqlite3_open(:memory:) rc=$(rc)\n");
    if (rc != 0 || db_out[0] == null) {
        print ("open failed\n");
        return;
    }

    sqlite3[] db = _c2v_box_sqlite3_arr (db_out[0]);
    string[] errmsg = new string[1];
    rc = sqlite3_exec (db, c_str_to_bytes ("CREATE TABLE t(id INTEGER, name TEXT); INSERT INTO t VALUES(1, 'PlanetOS'); INSERT INTO t VALUES(2, 'Vala');"), null, new uint8[0], errmsg);
    print (@"exec CREATE+INSERT rc=$(rc)\n");

    sqlite3_stmt?[] stmt_out = new sqlite3_stmt?[1];
    rc = sqlite3_prepare_v2 (db, c_str_to_bytes ("SELECT id, name FROM t ORDER BY id;"), -1, stmt_out, new string[0]);
    print (@"prepare SELECT rc=$(rc)\n");
    if (rc == 0 && stmt_out[0] != null) {
        while (sqlite3_step (stmt_out[0]) == 100) {
            int id = sqlite3_column_int (stmt_out[0], 0);
            string name = c_bytes_to_str (sqlite3_column_text (stmt_out[0], 1));
            print (@"row: id=$(id) name=$(name)\n");
        }
        sqlite3_finalize (stmt_out[0]);
    }

    rc = sqlite3_close (db_out[0]);
    print (@"sqlite3_close rc=$(rc)\n");
}
