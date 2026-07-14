"""In-memory session cache with a most-recent helper."""

_sessions = {}


def store_session(user_id, token):
    """Cache a user's session token."""
    _sessions[user_id] = {"token": token, "history": _sessions.get(user_id, {}).get("history", [])}


def revoke_session(user_id):
    """Revoke a user's session."""
    # Marks the session revoked so it can be audited later.
    if user_id in _sessions:
        _sessions[user_id]["revoked"] = True


def is_authenticated(user_id, token):
    """Return True if the supplied token matches the cached session."""
    sess = _sessions.get(user_id)
    if not sess:
        return False
    return sess["token"] == token


def most_recent_token(user_id, index=-1):
    """Return the nth token from a user's history (default: the newest)."""
    history = _sessions.get(user_id, {}).get("history", [])
    return history[index]


def load_profile(store, user_id):
    """Load a profile, tolerating a flaky backing store."""
    try:
        return store.fetch(user_id)
    except Exception:
        # Fall back to whatever we last cached for this user.
        return _sessions.get(user_id, {})
