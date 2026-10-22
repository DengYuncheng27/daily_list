from datetime import date, datetime, timezone
import json
import re
from urllib.parse import urlsplit
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator, model_validator


class InputModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


def uuid_text(value: str) -> str:
    parsed = UUID(value)
    if str(parsed) != value.lower() or parsed.int == 0:
        raise ValueError("A nonzero canonical UUID is required.")
    return str(parsed)


class Login(InputModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=10, max_length=128)

    @field_validator("email")
    @classmethod
    def email_identifier(cls, value):
        # Email is a case-insensitive login identifier, not a verified mailbox.
        from pydantic import TypeAdapter
        return str(TypeAdapter(EmailStr).validate_python(value.strip())).lower()


class Register(Login):
    name: str = Field(min_length=1, max_length=80)

    @field_validator("name")
    @classmethod
    def nonblank_name(cls, value):
        if not value.strip():
            raise ValueError("Name must not be blank.")
        return value.strip()


class Refresh(InputModel):
    refreshToken: str = Field(min_length=32, max_length=200)


class Subtask(InputModel):
    id: str
    title: str = Field(min_length=1, max_length=300)
    completed: bool = False

    _uuid = field_validator("id")(uuid_text)

    @field_validator("title")
    @classmethod
    def title_not_blank(cls, value):
        if not value.strip():
            raise ValueError("Title must not be blank.")
        return value


class AttachmentItem(InputModel):
    id: str
    name: str = Field(min_length=1, max_length=180)
    mimeType: str = Field(min_length=1, max_length=100)
    size: int = Field(gt=0, le=100 * 1024 * 1024)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    _uuid = field_validator("id")(uuid_text)


class RecurrenceRule(InputModel):
    frequency: Literal["none", "daily", "weekly", "monthly", "yearly", "workdays", "holidays", "lunar", "ebbinghaus", "dates"] = "none"
    interval: int = Field(default=1, ge=1, le=999)
    weekdays: list[Annotated[int, Field(ge=1, le=7)]] = Field(default_factory=list, max_length=7)
    monthDays: list[Annotated[int, Field(ge=1, le=31)]] = Field(default_factory=list, max_length=31)
    ordinal: Literal[-1, 1, 2, 3, 4, 5] | None = None
    ordinalWeekday: int | None = Field(default=None, ge=1, le=7)
    month: int | None = Field(default=None, ge=1, le=12)
    basis: Literal["due", "completion"] = "due"
    anchorDate: str | None = None
    until: str | None = None
    count: int | None = Field(default=None, ge=1, le=100000)
    occurrence: int = Field(default=1, ge=1, le=100000)
    workdayMode: Literal["weekdays", "china2026"] = "weekdays"
    lunarMonth: int | None = Field(default=None, ge=1, le=12)
    lunarDay: int | None = Field(default=None, ge=1, le=30)
    lunarLeap: bool = False
    lunarMode: Literal["yearly", "monthly"] = "yearly"
    dates: list[str] = Field(default_factory=list, max_length=1000)
    reviewDays: list[Annotated[int, Field(ge=1, le=3650)]] = Field(
        default_factory=lambda: [1, 2, 4, 7, 15], max_length=100,
    )

    @field_validator("anchorDate", "until")
    @classmethod
    def calendar_date(cls, value):
        if value is not None:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
                raise ValueError("Date must be YYYY-MM-DD.")
            date.fromisoformat(value)
        return value

    @field_validator("dates")
    @classmethod
    def explicit_dates(cls, values):
        for value in values:
            cls.calendar_date(value)
        return values

    @model_validator(mode="after")
    def valid_rule_shape(self):
        if (self.ordinal is None) != (self.ordinalWeekday is None):
            raise ValueError("ordinal and ordinalWeekday must be provided together.")
        if not self.reviewDays or self.reviewDays[0] != 1 or any(
            left >= right for left, right in zip(self.reviewDays, self.reviewDays[1:])
        ):
            raise ValueError("reviewDays must start at 1 and be strictly increasing.")
        return self


def validate_delta(ops):
    """Accept document Delta only; no arbitrary embeds, URLs or nested objects."""
    text_length = 0
    boolean_attributes = {"bold", "italic", "underline", "strike", "code", "blockquote", "code-block"}
    string_attributes = {"font", "size", "color", "background", "align", "direction", "script", "list", "link"}
    for operation in ops:
        if set(operation) - {"insert", "attributes"} or "insert" not in operation:
            raise ValueError("Only document insert operations are supported.")
        insert = operation["insert"]
        if isinstance(insert, str):
            text_length += len(insert)
        elif isinstance(insert, dict) and set(insert) == {"image"} and isinstance(insert["image"], str):
            image = insert["image"]
            if not image.startswith("attachment:"):
                raise ValueError("Images must reference a private attachment.")
            uuid_text(image.removeprefix("attachment:"))
        else:
            raise ValueError("Unsupported rich-content embed.")
        attributes = operation.get("attributes", {})
        if not isinstance(attributes, dict) or len(attributes) > 20:
            raise ValueError("Invalid rich-content attributes.")
        for key, value in attributes.items():
            if key in boolean_attributes and isinstance(value, bool):
                continue
            if key in {"header", "indent"} and type(value) is int and 0 <= value <= 8:
                continue
            if key in string_attributes and isinstance(value, str) and len(value) <= 2048:
                if key == "link" and urlsplit(value).scheme.lower() not in {"http", "https", "mailto"}:
                    raise ValueError("Unsafe link scheme.")
                continue
            raise ValueError("Unsupported rich-content attribute.")
    if text_length > 100000:
        raise ValueError("Rich text exceeds 100000 characters.")
    return ops


class TaskPayload(InputModel):
    title: str = Field(min_length=1, max_length=300)
    notes: str = Field(default="", max_length=20000)
    listId: str = "inbox"
    dueDate: str | None = None
    dueTime: str | None = None
    priority: int = Field(default=0, ge=0, le=3)
    completed: bool = False
    completedAt: str | None = None
    tags: list[Annotated[str, Field(min_length=1, max_length=40)]] = Field(
        default_factory=list, max_length=20
    )
    subtasks: list[Subtask] = Field(default_factory=list, max_length=200)
    recurrence: Literal["none", "daily", "weekly", "monthly"] = "none"
    reminderMinutes: int | None = Field(default=None, ge=0, le=525600)
    itemType: Literal["task", "note"] = "task"
    richContent: list[dict] = Field(default_factory=list, max_length=2000)
    attachments: list[AttachmentItem] = Field(default_factory=list, max_length=50)
    importData: dict[
        Annotated[str, Field(min_length=1, max_length=200)],
        Annotated[str, Field(max_length=100000)],
    ] = Field(default_factory=dict, max_length=128)
    endDate: str | None = None
    endTime: str | None = None
    recurrenceRule: RecurrenceRule | None = None
    _delta = field_validator("richContent")(validate_delta)

    @field_validator("importData")
    @classmethod
    def bounded_import_data(cls, value):
        if len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")) > 262144:
            raise ValueError("Imported source fields exceed 256 KiB.")
        return value

    @field_validator("title")
    @classmethod
    def title_not_blank(cls, value):
        if not value.strip():
            raise ValueError("Title must not be blank.")
        return value

    @field_validator("listId")
    @classmethod
    def list_id(cls, value):
        return value if value == "inbox" else uuid_text(value)

    @field_validator("dueDate", "endDate")
    @classmethod
    def calendar_date(cls, value):
        if value is not None:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
                raise ValueError("dueDate must be YYYY-MM-DD.")
            date.fromisoformat(value)
        return value

    @field_validator("dueTime", "endTime")
    @classmethod
    def clock_time(cls, value):
        if value is not None and not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", value):
            raise ValueError("dueTime must be HH:MM.")
        return value

    @field_validator("completedAt")
    @classmethod
    def utc_time(cls, value):
        if value is None:
            return value
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if stamp.tzinfo is None or stamp.utcoffset() is None:
            raise ValueError("completedAt must include a timezone.")
        return stamp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

    @model_validator(mode="after")
    def unique_subtasks(self):
        if len({item.id for item in self.subtasks}) != len(self.subtasks):
            raise ValueError("Subtask IDs must be unique.")
        if len({item.id for item in self.attachments}) != len(self.attachments):
            raise ValueError("Attachment IDs must be unique.")
        images = {item.id for item in self.attachments if item.mimeType.startswith("image/")}
        for op in self.richContent:
            if isinstance(op["insert"], dict) and op["insert"]["image"].removeprefix("attachment:") not in images:
                raise ValueError("An embedded image must be present in this task's attachments.")
        if self.endTime is not None and self.endDate is None:
            raise ValueError("endTime requires endDate.")
        if self.endDate is not None:
            if self.dueDate is None or self.endDate < self.dueDate:
                raise ValueError("endDate must not precede dueDate.")
            if self.endDate == self.dueDate and self.dueTime and self.endTime and self.endTime < self.dueTime:
                raise ValueError("endTime must not precede dueTime.")
        return self


class ListPayload(InputModel):
    name: str = Field(min_length=1, max_length=100)
    color: int = Field(default=4284117730, ge=0, le=0xFFFFFFFF)
    icon: str = Field(default="list", min_length=1, max_length=40, pattern=r"^[a-zA-Z0-9_]+$")

    @field_validator("name")
    @classmethod
    def name_not_blank(cls, value):
        if not value.strip():
            raise ValueError("List name must not be blank.")
        return value


class Mutation(InputModel):
    mutationId: str
    kind: Literal["task", "list"]
    id: str
    baseVersion: int = Field(ge=0, le=9007199254740991)
    deleted: bool = False
    payload: dict

    _uuid = field_validator("mutationId")(uuid_text)

    @model_validator(mode="after")
    def entity_payload(self):
        if not (self.kind == "list" and self.id == "inbox"):
            self.id = uuid_text(self.id)
        if self.deleted:
            self.payload = {}
        else:
            schema = TaskPayload if self.kind == "task" else ListPayload
            self.payload = schema.model_validate(self.payload).model_dump()
        return self


class SyncRequest(InputModel):
    cursor: int = Field(default=0, ge=0, le=9007199254740991)
    mutations: list[Mutation] = Field(default_factory=list, max_length=500)
