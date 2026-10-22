import pytest
from pydantic import ValidationError

from dayflow.models import TaskPayload
from dayflow.models import Mutation
from dayflow.sync import canonical, mutation_hash
from hashlib import sha256
from uuid import uuid4


def test_import_fields_round_trip_without_interpreting_markup():
    original = {"__source": "ticktick", "Content": "<script>not executable</script>\n中文", "Unknown": "kept"}
    task = TaskPayload(title="迁移", importData=original)
    assert task.model_dump()["importData"] == original
    assert TaskPayload(title="旧任务").importData == {}


@pytest.mark.parametrize("fields", [
    {str(i): "v" for i in range(129)},
    {"": "v"},
    {"x" * 201: "v"},
    {"Content": "a" * 100001},
    {"Content": "中" * 90000},
    {"Content": {"nested": "not allowed"}},
])
def test_import_fields_are_bounded_and_flat(fields):
    with pytest.raises(ValidationError):
        TaskPayload(title="迁移", importData=fields)


def test_optional_import_defaults_preserve_pre_upgrade_receipt_hash():
    mutation = Mutation(mutationId=str(uuid4()), kind="task", id=str(uuid4()),
                        baseVersion=0, payload={"title": "旧版待重试任务"})
    legacy = mutation.model_dump()
    for field in ("itemType", "richContent", "attachments", "importData", "endDate", "endTime", "recurrenceRule"):
        legacy["payload"].pop(field)
    assert mutation_hash(mutation) == sha256(canonical(legacy).encode("utf-8")).hexdigest()
    imported = mutation.model_copy(deep=True)
    imported.payload["importData"] = {"Content": "original"}
    assert mutation_hash(imported) != mutation_hash(mutation)
