"""FradSer/mcp-server-apple-events, MCP server (npm mcp-server-apple-events)."""

from __future__ import annotations

from ._util import first_json, named, pick, rec, rows

NAME = "apple-events"
KIND = "mcp"
VERSION = "1.6.2"
APPS = ["reminders", "calendar"]


def launch(tools_dir: str) -> list[str]:
    return ["node", tools_dir + "/apple-events/node_modules/mcp-server-apple-events/dist/index.js"]


def _call(tool: str, action: str, mapping: dict, **fixed):
    return lambda a: (tool, dict(named(a, mapping), action=action, **fixed))


OPS = {
    "reminders.lists": _call("reminders_lists", "read", {}),
    "reminders.list": _call("reminders_tasks", "read", {"filterList": "list", "showCompleted": "include_completed"}),
    "reminders.search": _call("reminders_tasks", "read", {"search": "query", "filterList": "list"}),
    "reminders.create": _call("reminders_tasks", "create", {"title": "title", "targetList": "list", "dueDate": "due", "note": "notes"}),
    "reminders.edit": _call("reminders_tasks", "update", {"id": "id", "title": "title", "dueDate": "due", "note": "notes"}),
    "reminders.complete": _call("reminders_tasks", "update", {"id": "id"}, completed=True),
    "reminders.delete": _call("reminders_tasks", "delete", {"id": "id"}),
    "calendar.calendars": _call("calendar_calendars", "read", {}),
    "calendar.events": _call("calendar_events", "read", {"startDate": "start", "endDate": "end", "filterCalendar": "calendar"}),
    "calendar.search": _call("calendar_events", "read", {"search": "query", "startDate": "start", "endDate": "end"}),
    "calendar.create": _call("calendar_events", "create", {"title": "title", "startDate": "start", "endDate": "end", "targetCalendar": "calendar", "location": "location", "note": "notes"}),
    "calendar.edit": _call("calendar_events", "update", {"id": "id", "title": "title", "startDate": "start", "endDate": "end", "location": "location", "note": "notes"}),
    "calendar.delete": _call("calendar_events", "delete", {"id": "id"}),
}


def _records(text: str) -> list:
    return rows(first_json(text) or [], "records", "record")


def _titled(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title")) for r in _records(text)]


def _reminders(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title"), due=r.get("dueDate"), completed=r.get("isCompleted"), list=r.get("list"), notes=r.get("notes")) for r in _records(text)]


def _events(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title"), start=pick(r, "startDateISO", "startDate"), end=pick(r, "endDateISO", "endDate"), calendar=r.get("calendar"),
                all_day=r.get("isAllDay"), location=r.get("location"), notes=r.get("notes")) for r in _records(text)]


PARSE = {
    "reminders.lists": _titled,
    "reminders.list": _reminders,
    "reminders.search": _reminders,
    "reminders.create": _reminders,
    "reminders.edit": _reminders,
    "reminders.complete": _reminders,
    "calendar.calendars": _titled,
    "calendar.events": _events,
    "calendar.search": _events,
    "calendar.create": _events,
    "calendar.edit": _events,
}

NOTES = {
    "*": "The text reply is a short sentence followed by a JSON envelope {provenance, records}. Exercised in the VM: reminders.lists, reminders.list, reminders.search, calendar.calendars, calendar.events, calendar.search. Launched without --require-write-confirmation (the server default).",
    "reminders.list": "Reminder dueDate is local wall-clock text ('YYYY-MM-DD HH:mm:ss') with no zone.",
    "reminders.search": "Search is a filter applied by the server after it fetches reminders.",
    "calendar.calendars": "The calendar id is the calendar's name, not the EventKit identifier.",
    "calendar.events": "Reads by day: the time part of start and end is ignored and the end day is exclusive. Parsers prefer startDateISO and endDateISO (UTC) and fall back to the wall-clock fields for all-day events.",
    "calendar.search": "Search is a filter applied after the fetch, inside the given date range.",
    "reminders.create": "untested: reply shape assumed to be the same envelope.",
    "reminders.edit": "untested.",
    "reminders.complete": "untested. Implemented as update with completed=true.",
    "reminders.delete": "untested. No confirmation by default.",
    "calendar.create": "untested. Takes the calendar name. All-day is inferred from a date-only start.",
    "calendar.edit": "untested.",
    "calendar.delete": "untested. No confirmation by default.",
}
