import json
from pathlib import Path

root = Path(__file__).resolve().parent
source = root / "brain/.system_generated/logs/transcript_full.jsonl"
destination = root / "chat_messages.md"

entries = []
for line in source.read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    item = json.loads(line)
    source_type = item.get("source", "")
    content = item.get("content")
    if source_type not in {"MODEL", "USER", "USER_EXPLICIT"} or not content:
        continue
    entries.append(
        f"## Step {item.get('step_index')} — {source_type} / {item.get('type', '')}\n\n"
        f"{content.rstrip()}\n"
    )

destination.write_text(
    "# Antigravity chat messages\n\n"
    "Conversation: `c5ba4666-5e2e-4b51-b55c-539f531a3928`\n\n"
    + "\n---\n\n".join(entries)
    + "\n",
    encoding="utf-8",
)
print(f"Extracted {len(entries)} messages to {destination}")
