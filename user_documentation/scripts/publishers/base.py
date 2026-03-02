"""Abstract base class for documentation publishers.

Each publisher adapter must implement these methods to support
the upsert workflow in publish_docs.py.
"""

from abc import ABC, abstractmethod
from pathlib import Path


class BasePublisher(ABC):
    """Interface that every doc-publishing backend must implement."""

    @abstractmethod
    def list_docs(self) -> list[dict]:
        """Return all existing docs in the target location.

        Each dict must contain at minimum:
            - "id": str   — unique identifier for the doc
            - "name": str — display name / title of the doc
        """

    @abstractmethod
    def create_doc(self, title: str) -> dict:
        """Create a new doc container and return its dict (same shape as list_docs items)."""

    @abstractmethod
    def list_pages(self, doc_id: str) -> list[dict]:
        """Return all pages inside a doc.

        Each dict must contain:
            - "id": str   — unique identifier for the page
            - "name": str — display name / title of the page
        """

    @abstractmethod
    def create_page(self, doc_id: str, name: str, content: str) -> dict:
        """Create a new page inside a doc with the given markdown content."""

    @abstractmethod
    def update_page(self, doc_id: str, page_id: str, content: str) -> dict:
        """Replace the content of an existing page."""

    @abstractmethod
    def upload_image(self, filepath: Path, filename: str) -> str:
        """Upload an image file and return its public URL.

        Return an empty string if upload is not supported or fails.
        """

    @abstractmethod
    def list_uploaded_images(self) -> dict[str, str]:
        """Return a mapping of filename → URL for previously uploaded images.

        Used for caching / deduplication. Return an empty dict if not supported.
        """
