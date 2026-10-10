"""
Plain-English questions over the Meridian gold layer, as the person who logged in.

Two ways to run it. Both use the same row access policies.

  Snowsight (Streamlit in Snowflake), app owned by role MERIDIAN_APP
    Log in as MERIDIAN_CEO, MERIDIAN_BM_MUMBAI, MERIDIAN_STAFF_MUMBAI or
    MERIDIAN_CUSTOMER. The password is checked by Snowflake before this file runs.
    The app reads CURRENT_USER() and looks the persona up. It does not ask for a
    second password: a password typed here would not change which rows the policy
    returns, because the query still runs as the Snowsight user.

  Laptop
    streamlit run 10_semantic_app/streamlit_app.py
    The form opens a real Snowflake connection as that user. Every question runs
    on that connection, so the same policies apply. The password is not stored.

Cortex Analyst is not in every region. If the API returns an error, read it back
to the class. The policies still apply to any SQL you run as that user.
"""
from __future__ import annotations

import json
import os
import re

import streamlit as st

try:
    import requests
except ImportError:  # Streamlit in Snowflake does not need it; the laptop login does
    requests = None

try:
    import snowflake.connector
except ImportError:
    snowflake = None

try:
    from snowflake.snowpark.context import get_active_session
except ImportError:
    get_active_session = None

try:
    import _snowflake
except ImportError:  # running outside Streamlit in Snowflake
    _snowflake = None

SEMANTIC_VIEW = "MERIDIAN_ANALYTICS.MARTS.SV_MERIDIAN_BANK"
API_PATH = "/api/v2/cortex/analyst/message"
SCOPE_SQL = """
select
    current_user() as snowflake_user,
    current_role() as snowflake_role,
    u.persona,
    u.branch_id,
    u.customer_id,
    b.branch_code,
    b.branch_name,
    c.full_name
from MERIDIAN_ANALYTICS.GOVERNANCE.V_MY_SCOPE u
left join MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH b
    on b.branch_id = u.branch_id
left join MERIDIAN_ANALYTICS.MARTS.DIM_CUSTOMER_CURRENT c
    on c.customer_id = u.customer_id
"""

SUGGESTIONS = [
    "How much approved card spend did we have on Flipkart and Amazon during sale events?",
    "What is the credit card approval rate by the segment the customer had when they applied?",
    "Who should we contact with a card offer before the next sale, and why?",
    "How many suspected fraudulent card authorizations did the rules flag?",
    "What was net posted flow in USD by branch country last month?",
]

PERSONA_LABEL = {
    "CEO": "Chief executive — every branch and every customer",
    "BRANCH_MANAGER": "Branch manager — customers whose home branch is yours",
    "STAFF": "Branch staff — same customers as the manager; email, phone and income are hidden",
    "CUSTOMER": "Customer — your own rows only",
}

# CONTAINS on the raw column so Search Optimization can be used. The column is stored
# uppercased. Two binds: the filter, and "exact id before a longer id that contains it".
_SEARCH = """
select entity_type, match_on, entity_id, search_text, occurred_on,
       amount_reporting, currency_code, summary, source_model
from MERIDIAN_ANALYTICS.MARTS.OMNI_SEARCH
where contains(search_text, {p})
order by iff(search_text = {p}, 0, 1), length(search_text), occurred_on desc nulls last
limit 50
"""


def snowsight_session():
    if get_active_session is None:
        return None
    try:
        return get_active_session()
    except Exception:
        return None


def query_frame(sql: str, params: tuple | None = None):
    session = st.session_state.get("sis_session")
    if session is not None:
        if params:
            frame = session.sql(sql, params=list(params)).to_pandas()
        else:
            frame = session.sql(sql).to_pandas()
    else:
        cursor = st.session_state.conn.cursor()
        try:
            cursor.execute(sql, params) if params else cursor.execute(sql)
            frame = cursor.fetch_pandas_all()
        finally:
            cursor.close()
    frame.columns = [str(column).lower() for column in frame.columns]
    return frame


def analyst_local(question: str) -> dict:
    if requests is None:
        raise RuntimeError("The requests package is not installed. pip install requests")
    conn = st.session_state.conn
    token = conn.rest.token
    response = requests.post(
        f"https://{conn.host}{API_PATH}",
        headers={
            "Authorization": f'Snowflake Token="{token}"',
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        json={
            "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
            "semantic_view": SEMANTIC_VIEW,
        },
        timeout=60,
    )
    try:
        payload = response.json()
    except ValueError:
        payload = {"message": response.text}
    if response.status_code >= 400 or "message" not in payload:
        raise RuntimeError(payload.get("message") or payload)
    return payload


def analyst_snowsight(question: str) -> dict:
    if _snowflake is None:
        raise RuntimeError("Cortex Analyst is only callable inside Streamlit in Snowflake from this path.")
    body = {
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
        "semantic_view": SEMANTIC_VIEW,
    }
    response = _snowflake.send_snow_api_request("POST", API_PATH, {}, {}, body, {}, 60000)
    payload = json.loads(response["content"])
    if response.get("status", 200) >= 400 or "message" not in payload:
        raise RuntimeError(payload.get("message") or payload)
    return payload


def parts(payload: dict) -> tuple[str, str | None]:
    text, sql = [], None
    for block in payload["message"]["content"]:
        if block.get("type") == "text":
            text.append(block.get("text", ""))
        elif block.get("type") == "sql":
            sql = block.get("statement")
    return "\n".join(text), sql


def _blank(value: object) -> object:
    if value is None:
        return None
    if isinstance(value, float) and value != value:
        return None
    return value


def load_scope() -> dict | None:
    frame = query_frame(SCOPE_SQL)
    if frame.empty:
        return None
    row = frame.iloc[0]
    return {key: _blank(row[key]) for key in frame.columns}


def scope_caption(scope: dict | None, snowflake_user: str) -> str:
    if scope is None or scope.get("persona") is None:
        return (
            f"Signed in as **{snowflake_user}**, who is not mapped to a persona. "
            "Inside Snowsight the row policies deny an unmapped viewer, so answers will be empty. "
            "Outside the app, a builder role (MERIDIAN_TRANSFORMER, ANALYST or ML) sees the whole bank. "
            "Log in as MERIDIAN_CEO, MERIDIAN_BM_MUMBAI, MERIDIAN_STAFF_MUMBAI or MERIDIAN_CUSTOMER."
        )
    persona = str(scope["persona"])
    label = PERSONA_LABEL.get(persona, persona)
    detail = f"Signed in as **{snowflake_user}**. Persona **{persona}** — {label}."
    if scope.get("branch_code"):
        detail += f" Branch **{scope['branch_code']}** ({scope.get('branch_name') or ''})."
    if scope.get("full_name"):
        detail += f" Customer **{scope['full_name']}** (customer_id {scope.get('customer_id')})."
    detail += " The role was not chosen in this screen. The username selected it."
    return detail


def login_form() -> None:
    st.title("Meridian Bank")
    st.caption("Sign in with a Snowflake user. The password is checked by Snowflake, and the username selects what you can see.")
    with st.form("login"):
        account = st.text_input(
            "Snowflake account identifier",
            value=os.getenv("SNOWFLAKE_ACCOUNT", ""),
            help="The same account locator you use in Snowsight, for example xy12345.ap-south-1.aws.",
        )
        username = st.text_input(
            "Username",
            help="MERIDIAN_CEO, MERIDIAN_BM_MUMBAI, MERIDIAN_STAFF_MUMBAI or MERIDIAN_CUSTOMER.",
        )
        password = st.text_input("Password", type="password")
        submitted = st.form_submit_button("Sign in")
    if not submitted:
        return
    if not account or not username or not password:
        st.error("Account, username and password are all required.")
        return
    if snowflake is None:
        st.error("The Snowflake connector is not installed. pip install snowflake-connector-python")
        return
    try:
        conn = snowflake.connector.connect(
            account=account.strip(),
            user=username.strip(),
            password=password,
            warehouse="WH_BI_XS",
        )
    except Exception as exc:
        st.error("Snowflake refused this login. " + str(exc))
        return
    st.session_state.conn = conn
    st.session_state.messages = []
    st.rerun()


def render_chat() -> None:
    if "messages" not in st.session_state:
        st.session_state.messages = []

    for saved in st.session_state.messages:
        with st.chat_message(saved["role"]):
            st.markdown(saved["text"])
            if saved.get("sql"):
                with st.expander("SQL the semantic view produced"):
                    st.code(saved["sql"], language="sql")
            if saved.get("table") is not None:
                st.dataframe(saved["table"], use_container_width=True)

    pending = st.session_state.pop("pending", None)
    question = st.chat_input("Ask about spend, approvals, fraud or who to contact")
    if question is None and pending:
        question = pending

    cols = st.columns(len(SUGGESTIONS))
    for col, suggestion in zip(cols, SUGGESTIONS):
        if col.button(suggestion, use_container_width=True):
            st.session_state.pending = suggestion
            st.rerun()

    if not question:
        return

    with st.chat_message("user"):
        st.markdown(question)
    try:
        if st.session_state.get("sis_session") is not None:
            payload = analyst_snowsight(question)
        else:
            payload = analyst_local(question)
        text, sql = parts(payload)
        table = query_frame(sql) if sql else None
    except Exception as exc:
        text, sql, table = (
            "Cortex Analyst did not answer. Confirm the semantic view exists and that "
            "this account region has Cortex Analyst enabled. The row access policy still "
            "applies to any SQL you run as this user.\n\n" + str(exc),
            None,
            None,
        )
    with st.chat_message("assistant"):
        st.markdown(text)
        if sql:
            with st.expander("SQL the semantic view produced"):
                st.code(sql, language="sql")
        if table is not None:
            st.dataframe(table, use_container_width=True)
    st.session_state.messages.append({"role": "user", "text": question, "sql": None, "table": None})
    st.session_state.messages.append({"role": "assistant", "text": text, "sql": sql, "table": table})


def render_search() -> None:
    st.caption(
        "Type at least 4 letters or digits from a transaction id, reference number, "
        "account number, customer id or card authorization. Names and email are not searchable. "
        "The same search returns only the rows this login may see."
    )
    with st.form("omni"):
        raw = st.text_input("Identifier", placeholder="for example 4821")
        submitted = st.form_submit_button("Find")
    if not submitted:
        return
    fragment = re.sub(r"[^A-Za-z0-9]", "", raw).upper()
    if len(fragment) < 4:
        st.warning("Use at least 4 letters or digits. A shorter piece matches too much of the bank.")
        return
    if len(fragment) > 40:
        st.warning("That is too long to be part of an identifier.")
        return
    placeholder = "?" if st.session_state.get("sis_session") is not None else "%s"
    try:
        frame = query_frame(_SEARCH.format(p=placeholder), (fragment, fragment))
    except Exception as exc:
        st.error(
            "Search failed. Build the omni_search model, then run 03_snowflake/07_omni_search.sql "
            "if you want the substring access path.\n\n" + str(exc)
        )
        return
    st.caption(
        f"{len(frame)} match(es). An exact id is listed before a longer id that only contains these characters. "
        "entity_type says which part of the platform the hit came from."
    )
    st.dataframe(frame, use_container_width=True)


def main() -> None:
    st.set_page_config(page_title="Meridian Analyst", layout="wide")
    session = snowsight_session()
    if session is not None:
        st.session_state.sis_session = session
    elif "sis_session" not in st.session_state:
        st.session_state.sis_session = None

    signed_in = st.session_state.get("sis_session") is not None or st.session_state.get("conn") is not None
    if not signed_in:
        login_form()
        return

    try:
        who = query_frame("select current_user() as snowflake_user")
        snowflake_user = str(who.iloc[0]["snowflake_user"])
        scope = load_scope()
    except Exception as exc:
        st.title("Meridian Bank")
        st.error(
            "Signed in, but the scope view could not be read. Run 03_snowflake/06_row_level_security.sql "
            "after dbt build.\n\n" + str(exc)
        )
        return

    st.title("Meridian Bank")
    st.markdown(scope_caption(scope, snowflake_user))
    st.caption(
        "The same question, the same SQL. A row access policy removes the rows this login cannot see. "
        "Open the SQL and compare it across the four users. "
        "In Snowsight, sign out and sign in as the other user — a role picked in a worksheet does not change CURRENT_USER()."
    )
    if st.session_state.get("sis_session") is None and st.button("Sign out"):
        conn = st.session_state.pop("conn", None)
        if conn is not None:
            conn.close()
        st.session_state.messages = []
        st.rerun()
    ask, find = st.tabs(["Ask in English", "Find an identifier"])
    with ask:
        render_chat()
    with find:
        render_search()


main()
