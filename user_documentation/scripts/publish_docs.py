#!/usr/bin/env python3
"""Publish user documentation to an external documentation platform.

Maps the local directory structure to docs/pages on the target platform:
  - Each subdirectory -> one Doc (container)
  - Each .md file in a subdirectory -> one Page in that Doc
  - Root-level .md files -> standalone Doc with one Page
  - README.md files are excluded

Uses upsert logic (create-or-update) so re-runs are safe and idempotent.
Images are uploaded via the publisher's image API and referenced via CDN URLs.

Required env vars:
  PUBLISH_TARGET  - Publisher backend to use (default: "clickup")
                    Each publisher defines its own required env vars;
                    see publishers/<target>.py for details.

Optional env vars:
  DOCS_DIR        - Override the docs directory path
"""

import argparse
import hashlib
import logging
import re
import sys
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s: %(message)s",
)
log = logging.getLogger(__name__)

LARGE_FILE_THRESHOLD = 50 * 1024  # 50 KB


# ---------------------------------------------------------------------------
# Image processor
# ---------------------------------------------------------------------------


class ImageProcessor:
    """Handles image uploads and markdown URL replacement."""

    IMAGE_RE = re.compile(r"!\[([^\]]*)\]\((?!https?://)([^)]+)\)")

    def __init__(self, publisher, base_dir: Path):
        self.publisher = publisher
        self.base_dir = base_dir
        self._cache: dict[str, str] | None = None
        self.upload_count = 0
        self.skip_count = 0

    @property
    def cache(self) -> dict[str, str]:
        if self._cache is None:
            try:
                self._cache = self.publisher.list_uploaded_images()
            except Exception as exc:
                log.warning("Could not list uploaded images: %s", exc)
                self._cache = {}
        return self._cache

    @staticmethod
    def _file_hash(filepath: Path) -> str:
        return hashlib.sha256(filepath.read_bytes()).hexdigest()[:12]

    @staticmethod
    def _upload_name(rel_image_path: str, filepath: Path) -> str:
        path_hash = hashlib.sha256(rel_image_path.encode()).hexdigest()[:8]
        return f"{path_hash}_{filepath.name}"

    def process_markdown(self, content: str, md_file: Path) -> str:
        """Replace local image references with uploaded CDN URLs."""
        if not self.IMAGE_RE.search(content):
            return content

        md_dir = md_file.parent

        def _replace(match: re.Match) -> str:
            alt_text = match.group(1)
            image_path = match.group(2)

            filepath = (md_dir / image_path).resolve()
            if not filepath.is_file():
                log.warning(
                    "Image not found: %s (referenced in %s)", image_path, md_file.name
                )
                return match.group(0)

            upload_name = self._upload_name(image_path, filepath)

            if upload_name in self.cache:
                self.skip_count += 1
                log.info("Image cached, reusing: %s", upload_name)
                return f"![{alt_text}]({self.cache[upload_name]})"

            try:
                cdn_url = self.publisher.upload_image(filepath, upload_name)
                if cdn_url:
                    self.cache[upload_name] = cdn_url
                    self.upload_count += 1
                    log.info("Uploaded image: %s -> %s", upload_name, cdn_url)
                    return f"![{alt_text}]({cdn_url})"
                else:
                    log.warning("Upload returned no URL for %s", upload_name)
                    return match.group(0)
            except Exception as exc:
                log.warning("Failed to upload image %s: %s", upload_name, exc)
                return match.group(0)

        return self.IMAGE_RE.sub(_replace, content)


# ---------------------------------------------------------------------------
# Content processing
# ---------------------------------------------------------------------------

FRONTMATTER_RE = re.compile(r"\A---\s*\n.*?\n---\s*\n", re.DOTALL)
LEADING_H1_RE = re.compile(r"\A\s*#\s+[^\n]+\n*")


def process_content(raw: str, page_name: str) -> str:
    """Strip frontmatter and leading H1 if it duplicates the page name."""
    content = FRONTMATTER_RE.sub("", raw)

    h1_match = LEADING_H1_RE.match(content)
    if h1_match:
        h1_text = h1_match.group(0).strip().lstrip("#").strip()
        if h1_text.lower() == page_name.lower():
            content = content[h1_match.end():]

    return content.strip()


def filename_to_title(filename: str) -> str:
    stem = Path(filename).stem
    return stem.replace("-", " ").replace("_", " ").title()


def dirname_to_title(dirname: str) -> str:
    return dirname.replace("-", " ").replace("_", " ").title()


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------


class DocPublisher:
    """Scans local docs and upserts to the configured publisher backend."""

    def __init__(self, publisher, docs_dir: Path, image_processor: ImageProcessor):
        self.publisher = publisher
        self.docs_dir = docs_dir
        self.image_processor = image_processor
        self.stats = {
            "docs_created": 0,
            "docs_updated": 0,
            "pages_created": 0,
            "pages_updated": 0,
            "files_skipped": 0,
            "errors": 0,
        }

    def _get_existing_docs(self) -> dict[str, dict]:
        docs = self.publisher.list_docs()
        result = {}
        for d in docs:
            name = d.get("name", "")
            if name:
                result[name.lower()] = d
        log.info("Found %d existing docs", len(result))
        return result

    def _get_existing_pages(self, doc_id: str) -> dict[str, dict]:
        pages = self.publisher.list_pages(doc_id)
        result = {}
        for p in pages:
            name = p.get("name", "")
            if name:
                result[name.lower()] = p
        log.info("  Found %d existing pages in doc", len(result))
        return result

    def _upsert_page(
        self, doc_id: str, page_name: str, content: str, existing_pages: dict
    ) -> None:
        key = page_name.lower()
        if key in existing_pages:
            page_id = existing_pages[key]["id"]
            log.info("  Updating page: %s (id=%s)", page_name, page_id)
            self.publisher.update_page(doc_id, page_id, content)
            self.stats["pages_updated"] += 1
        else:
            log.info("  Creating page: %s", page_name)
            self.publisher.create_page(doc_id, page_name, content)
            self.stats["pages_created"] += 1

    def _ensure_doc(self, title: str, existing_docs: dict) -> str:
        key = title.lower()
        if key in existing_docs:
            doc_id = existing_docs[key]["id"]
            log.info("Doc exists: %s (id=%s)", title, doc_id)
            self.stats["docs_updated"] += 1
            return doc_id
        else:
            log.info("Creating doc: %s", title)
            resp = self.publisher.create_doc(title)
            doc_id = resp.get("id", "")
            if not doc_id:
                raise RuntimeError(f"Failed to create doc '{title}': {resp}")
            self.stats["docs_created"] += 1
            existing_docs[key] = resp
            return doc_id

    def _read_and_validate(self, md_file: Path) -> str | None:
        if md_file.stat().st_size > LARGE_FILE_THRESHOLD:
            log.warning(
                "Large file (%d bytes): %s", md_file.stat().st_size, md_file.name
            )

        raw = md_file.read_text(encoding="utf-8")
        if not raw.strip():
            log.warning("Skipping empty file: %s", md_file)
            self.stats["files_skipped"] += 1
            return None
        return raw

    def publish(self) -> None:
        if not self.docs_dir.is_dir():
            log.error("Docs directory not found: %s", self.docs_dir)
            self.stats["errors"] += 1
            return

        existing_docs = self._get_existing_docs()

        subdirs = sorted(
            [d for d in self.docs_dir.iterdir() if d.is_dir()],
            key=lambda p: p.name,
        )
        root_md_files = sorted(
            [
                f
                for f in self.docs_dir.iterdir()
                if f.is_file()
                and f.suffix.lower() == ".md"
                and f.name.lower() != "readme.md"
            ],
            key=lambda p: p.name,
        )

        for subdir in subdirs:
            md_files = sorted(
                [
                    f
                    for f in subdir.iterdir()
                    if f.is_file()
                    and f.suffix.lower() == ".md"
                    and f.name.lower() != "readme.md"
                ],
                key=lambda p: p.name,
            )
            if not md_files:
                log.warning("Empty directory (no .md files): %s", subdir.name)
                self.stats["files_skipped"] += 1
                continue

            doc_title = dirname_to_title(subdir.name)
            try:
                doc_id = self._ensure_doc(doc_title, existing_docs)
                existing_pages = self._get_existing_pages(doc_id)

                for md_file in md_files:
                    raw = self._read_and_validate(md_file)
                    if raw is None:
                        continue
                    page_name = filename_to_title(md_file.name)
                    content = process_content(raw, page_name)
                    content = self.image_processor.process_markdown(content, md_file)
                    self._upsert_page(doc_id, page_name, content, existing_pages)

            except Exception as exc:
                log.error("Error processing directory %s: %s", subdir.name, exc)
                self.stats["errors"] += 1

        for md_file in root_md_files:
            raw = self._read_and_validate(md_file)
            if raw is None:
                continue

            doc_title = filename_to_title(md_file.name)
            page_name = doc_title

            try:
                doc_id = self._ensure_doc(doc_title, existing_docs)
                existing_pages = self._get_existing_pages(doc_id)
                content = process_content(raw, page_name)
                content = self.image_processor.process_markdown(content, md_file)
                self._upsert_page(doc_id, page_name, content, existing_pages)
            except Exception as exc:
                log.error("Error processing file %s: %s", md_file.name, exc)
                self.stats["errors"] += 1

    def print_summary(self) -> None:
        log.info("--- Publish Summary ---")
        log.info("Docs created:  %d", self.stats["docs_created"])
        log.info("Docs updated:  %d", self.stats["docs_updated"])
        log.info("Pages created: %d", self.stats["pages_created"])
        log.info("Pages updated: %d", self.stats["pages_updated"])
        log.info("Files skipped: %d", self.stats["files_skipped"])
        log.info("Errors:        %d", self.stats["errors"])
        if self.image_processor.upload_count or self.image_processor.skip_count:
            log.info("Images uploaded: %d", self.image_processor.upload_count)
            log.info("Images cached:   %d", self.image_processor.skip_count)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    import os as _os

    parser = argparse.ArgumentParser(
        description="Publish user documentation to an external platform.",
    )
    parser.add_argument(
        "--target",
        default=_os.environ.get("PUBLISH_TARGET", "clickup"),
        help="Publisher backend (default: $PUBLISH_TARGET or 'clickup')",
    )
    parser.add_argument(
        "--docs-dir",
        default=_os.environ.get("DOCS_DIR", ""),
        help="Path to documentation directory (default: $DOCS_DIR or auto-detect)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate configuration and exit without publishing",
    )
    parser.add_argument(
        "--list-targets",
        action="store_true",
        help="List available publisher targets and exit",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    # Import publisher registry
    from publishers import available_targets, get_publisher

    if args.list_targets:
        print("Available publish targets:")
        for t in available_targets():
            print(f"  - {t}")
        return 0

    # Resolve docs directory
    if args.docs_dir:
        docs_dir = Path(args.docs_dir)
    else:
        docs_dir = Path(__file__).resolve().parent.parent / "docs" / "user_documentation"

    log.info("Publish target: %s", args.target)
    log.info("Docs directory: %s", docs_dir)

    if args.dry_run:
        log.info("Dry run — validating configuration...")
        try:
            publisher = get_publisher(args.target)
            log.info("Publisher loaded: %s", type(publisher).__name__)
        except ValueError as exc:
            log.error("%s", exc)
            return 1
        except KeyError as exc:
            log.error("Missing required env var: %s", exc)
            return 1
        except Exception as exc:
            log.error("Publisher init failed: %s", exc)
            return 1

        if not docs_dir.is_dir():
            log.error("Docs directory not found: %s", docs_dir)
            return 1

        md_count = sum(
            1
            for f in docs_dir.rglob("*.md")
            if f.name.lower() != "readme.md"
        )
        log.info("Found %d markdown files", md_count)
        log.info("Dry run complete — configuration is valid.")
        return 0

    # Real run
    try:
        publisher = get_publisher(args.target)
    except ValueError as exc:
        log.error("%s", exc)
        return 1
    except KeyError as exc:
        log.error("Missing required env var: %s", exc)
        return 1
    except Exception as exc:
        log.error("Publisher init failed (check env vars): %s", exc)
        return 1

    image_processor = ImageProcessor(publisher, docs_dir)
    orchestrator = DocPublisher(publisher, docs_dir, image_processor)

    orchestrator.publish()
    orchestrator.print_summary()

    return 1 if orchestrator.stats["errors"] > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
