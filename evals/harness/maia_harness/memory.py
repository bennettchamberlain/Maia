"""A directory of text files, sandboxed to one root.

The agent never receives a path outside that root. Symlinks are rejected
so a write cannot escape through a link.
"""

from __future__ import annotations

from pathlib import Path, PurePosixPath

_SUFFIXES = {".md", ".markdown", ".txt"}
_MAX_CHARS = 16_000


class MemoryPathError(Exception):
    pass


class Memory:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)

    def _file(self, raw: object) -> Path:
        if not isinstance(raw, str) or not raw.strip() or "\x00" in raw:
            raise MemoryPathError("path is required")
        rel = PurePosixPath(raw.strip().replace("\\", "/"))
        bad = rel.is_absolute() or not rel.parts
        bad = bad or any(part in {"", ".", ".."} for part in rel.parts)
        if bad:
            raise MemoryPathError("path must stay inside the memory directory")
        current = self.root
        for part in rel.parts:
            current = current / part
            if current.is_symlink():
                raise MemoryPathError("symlinks are not allowed")
        if current.suffix.lower() not in _SUFFIXES:
            raise MemoryPathError("only .md, .markdown, or .txt files are allowed")
        return current

    def list_files(self) -> list[tuple[str, int]]:
        rows: list[tuple[str, int]] = []
        for path in sorted(self.root.rglob("*")):
            if path.is_symlink() or not path.is_file():
                continue
            rows.append((str(path.relative_to(self.root)), path.stat().st_size))
        return rows

    def read(self, raw: object) -> str:
        path = self._file(raw)
        if not path.is_file():
            raise MemoryPathError("no such file")
        return path.read_text(encoding="utf-8", errors="replace")

    def write(self, raw: object, content: object) -> str:
        if not isinstance(content, str):
            raise MemoryPathError("content must be text")
        if len(content) > _MAX_CHARS:
            raise MemoryPathError("content exceeds 16000 characters")
        path = self._file(raw)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return str(path.relative_to(self.root))

    def edit(self, raw: object, old: object, new: object) -> str:
        if not isinstance(old, str) or not old:
            raise MemoryPathError("old text is empty")
        if not isinstance(new, str):
            raise MemoryPathError("new text must be a string")
        path = self._file(raw)
        if not path.is_file():
            raise MemoryPathError("no such file")
        text = path.read_text(encoding="utf-8", errors="replace")
        if old not in text:
            raise MemoryPathError("old text not found")
        updated = text.replace(old, new, 1)
        if len(updated) > _MAX_CHARS:
            raise MemoryPathError("file would exceed 16000 characters")
        path.write_text(updated, encoding="utf-8")
        return str(path.relative_to(self.root))

    def snapshot(self) -> dict[str, str]:
        return {rel: self.read(rel) for rel, _size in self.list_files()}
