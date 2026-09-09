"""Azure SQL helper — pure-Python TDS driver with AAD access-token auth.

Flex Consumption Python images don't ship msodbcsql18, so pyodbc is off the
table. `python-tds` speaks TDS directly and accepts an AAD access token via
the `access_token` kwarg. The Function App's system-assigned MI is granted
db_datareader + db_datawriter on sql-db-triage (see grant-function-mi.sql).
"""
from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Iterator

import certifi
import pytds
from azure.identity import DefaultAzureCredential

SQL_SERVER = os.environ["SQL_SERVER"]
SQL_DATABASE = os.environ["SQL_DATABASE"]

_credential = DefaultAzureCredential()


def _access_token() -> str:
    return _credential.get_token("https://database.windows.net/.default").token


@contextmanager
def connect(autocommit: bool = False) -> Iterator[pytds.Connection]:
    # pytds 1.15+ takes a zero-arg callable returning the token, not a bare
    # token string. Passing the callable lets the driver refresh mid-session
    # if the connection reauths — handy for long-running admin scripts.
    conn = pytds.connect(
        server=SQL_SERVER,
        database=SQL_DATABASE,
        port=1433,
        access_token_callable=_access_token,
        # pytds negotiates TLS when a CA bundle is supplied. Azure SQL
        # requires encryption; without cafile the driver's login handshake
        # fails with "Client does not have encryption enabled".
        cafile=certifi.where(),
        autocommit=autocommit,
    )
    try:
        yield conn
    finally:
        conn.close()


def valid_ident(name: str) -> str:
    """Whitelist SQL identifiers to schema.table / column-name shape.

    All parameterizable values go through pytds's `%s` placeholders. This
    function is only for identifiers that must be spliced into SQL text
    (table names, column names) since T-SQL does not parameterize those.
    """
    if not name or not all(c.isalnum() or c in "._" for c in name):
        raise ValueError(f"invalid identifier: {name!r}")
    return name
