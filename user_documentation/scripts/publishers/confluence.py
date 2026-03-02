"""Confluence publisher adapter — skeleton/stub.

Shows how to add a new publisher backend. Implement each method
using the Confluence REST API (or the atlassian-python-api library).

Required env vars (when implemented):
    CONFLUENCE_URL       — e.g. https://your-domain.atlassian.net/wiki
    CONFLUENCE_USERNAME  — Atlassian account email
    CONFLUENCE_API_TOKEN — API token (not password)
    CONFLUENCE_SPACE_KEY — Target space key (e.g. "DOCS")

Optional env vars:
    CONFLUENCE_PARENT_PAGE_ID — Parent page under which docs are created
"""

import logging
import os
from pathlib import Path

from .base import BasePublisher

log = logging.getLogger(__name__)


class ConfluencePublisher(BasePublisher):
    """Publishes documentation to Confluence Cloud.

    This is a skeleton — each method raises NotImplementedError.
    Replace with real Confluence API calls when ready.
    """

    def __init__(self):
        self.url = os.environ["CONFLUENCE_URL"]
        self.username = os.environ["CONFLUENCE_USERNAME"]
        self.token = os.environ["CONFLUENCE_API_TOKEN"]
        self.space_key = os.environ["CONFLUENCE_SPACE_KEY"]
        self.parent_page_id = os.environ.get("CONFLUENCE_PARENT_PAGE_ID", "")

    def list_docs(self) -> list[dict]:
        raise NotImplementedError(
            "Confluence publisher not yet implemented. "
            "Use the Confluence REST API to list child pages under the parent page."
        )

    def create_doc(self, title: str) -> dict:
        raise NotImplementedError("Confluence publisher not yet implemented.")

    def list_pages(self, doc_id: str) -> list[dict]:
        raise NotImplementedError("Confluence publisher not yet implemented.")

    def create_page(self, doc_id: str, name: str, content: str) -> dict:
        raise NotImplementedError("Confluence publisher not yet implemented.")

    def update_page(self, doc_id: str, page_id: str, content: str) -> dict:
        raise NotImplementedError("Confluence publisher not yet implemented.")

    def upload_image(self, filepath: Path, filename: str) -> str:
        raise NotImplementedError("Confluence publisher not yet implemented.")

    def list_uploaded_images(self) -> dict[str, str]:
        raise NotImplementedError("Confluence publisher not yet implemented.")
