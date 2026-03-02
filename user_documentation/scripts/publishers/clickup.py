"""ClickUp publisher adapter.

Maps the local directory structure to ClickUp Docs/Pages via the v3 API,
with image uploads via the v2 attachment API.

Required env vars:
    CLICKUP_API_TOKEN           — ClickUp API token (secret)
    CLICKUP_WORKSPACE_ID        — Workspace ID
    CLICKUP_FOLDER_ID           — Target folder ID for docs

Optional env vars:
    CLICKUP_IMAGE_HOST_TASK_ID  — Task ID used for image attachment uploads
"""

import json
import logging
import mimetypes
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from .base import BasePublisher

log = logging.getLogger(__name__)


class ClickUpAPIError(Exception):
    """Raised when the ClickUp API returns an error."""

    def __init__(self, status_code: int, message: str, url: str = ""):
        self.status_code = status_code
        self.url = url
        super().__init__(f"HTTP {status_code} from {url}: {message}")


class ClickUpPublisher(BasePublisher):
    """Publishes documentation to ClickUp Docs."""

    BASE_V3 = "https://api.clickup.com/api/v3"
    BASE_V2 = "https://api.clickup.com/api/v2"
    MAX_RETRIES = 3

    def __init__(self):
        self.token = os.environ["CLICKUP_API_TOKEN"]
        self.workspace_id = os.environ["CLICKUP_WORKSPACE_ID"]
        self.folder_id = os.environ["CLICKUP_FOLDER_ID"]
        self.image_task_id = os.environ.get("CLICKUP_IMAGE_HOST_TASK_ID", "")

    # -- low-level helpers ---------------------------------------------------

    def _headers(self, content_type: str = "application/json") -> dict:
        h = {"Authorization": self.token}
        if content_type:
            h["Content-Type"] = content_type
        return h

    def _request(
        self,
        method: str,
        url: str,
        data: bytes | None = None,
        headers: dict | None = None,
        retry: int = 0,
    ) -> dict | list:
        hdrs = headers or self._headers()
        req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
        try:
            with urllib.request.urlopen(req) as resp:
                body = resp.read().decode("utf-8")
                if not body.strip():
                    return {}
                return json.loads(body)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            if exc.code == 429 and retry < self.MAX_RETRIES:
                wait = 2 ** (retry + 1)
                log.warning(
                    "Rate limited, waiting %ds (attempt %d/%d)",
                    wait,
                    retry + 1,
                    self.MAX_RETRIES,
                )
                time.sleep(wait)
                return self._request(method, url, data, headers, retry + 1)
            raise ClickUpAPIError(exc.code, body, url) from exc

    def _get(self, url: str) -> dict | list:
        return self._request("GET", url)

    def _post(self, url: str, payload: dict) -> dict | list:
        data = json.dumps(payload).encode("utf-8")
        return self._request("POST", url, data=data)

    def _put(self, url: str, payload: dict) -> dict | list:
        data = json.dumps(payload).encode("utf-8")
        return self._request("PUT", url, data=data)

    # -- BasePublisher implementation ----------------------------------------

    def list_docs(self) -> list[dict]:
        url = (
            f"{self.BASE_V3}/workspaces/{self.workspace_id}/docs"
            f"?parent_id={self.folder_id}&parent_type=5"
        )
        resp = self._get(url)
        raw = resp if isinstance(resp, list) else resp.get("docs", [])
        # Normalize to standard shape
        return [
            {
                "id": d.get("id", "") or d.get("_id", ""),
                "name": d.get("name", "") or d.get("title", ""),
            }
            for d in raw
            if (d.get("id") or d.get("_id"))
        ]

    def create_doc(self, title: str) -> dict:
        url = f"{self.BASE_V3}/workspaces/{self.workspace_id}/docs"
        payload = {
            "name": title,
            "parent": {"id": self.folder_id, "type": 5},
            "visibility": "PUBLIC",
            "create_page": False,
        }
        resp = self._post(url, payload)
        if isinstance(resp, list):
            resp = resp[0] if resp else {}
        return {
            "id": resp.get("id", "") or resp.get("_id", ""),
            "name": resp.get("name", "") or resp.get("title", ""),
        }

    def list_pages(self, doc_id: str) -> list[dict]:
        url = f"{self.BASE_V3}/workspaces/{self.workspace_id}/docs/{doc_id}/pages"
        resp = self._get(url)
        raw = resp if isinstance(resp, list) else resp.get("pages", [])
        return [{"id": p.get("id", ""), "name": p.get("name", "")} for p in raw]

    def create_page(self, doc_id: str, name: str, content: str) -> dict:
        url = f"{self.BASE_V3}/workspaces/{self.workspace_id}/docs/{doc_id}/pages"
        payload = {
            "name": name,
            "content": content,
            "content_format": "text/md",
        }
        resp = self._post(url, payload)
        if isinstance(resp, list):
            resp = resp[0] if resp else {}
        return {"id": resp.get("id", ""), "name": resp.get("name", "")}

    def update_page(self, doc_id: str, page_id: str, content: str) -> dict:
        url = (
            f"{self.BASE_V3}/workspaces/{self.workspace_id}"
            f"/docs/{doc_id}/pages/{page_id}"
        )
        payload = {
            "content": content,
            "content_edit_mode": "replace",
            "content_format": "text/md",
        }
        resp = self._put(url, payload)
        if isinstance(resp, list):
            resp = resp[0] if resp else {}
        return {"id": resp.get("id", ""), "name": resp.get("name", "")}

    def upload_image(self, filepath: Path, filename: str) -> str:
        if not self.image_task_id:
            return ""

        url = f"{self.BASE_V2}/task/{self.image_task_id}/attachment"
        boundary = f"----PythonBoundary{int(time.time() * 1000)}"

        mime_type = mimetypes.guess_type(str(filepath))[0] or "application/octet-stream"
        file_data = filepath.read_bytes()

        body = (
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="attachment"; filename="{filename}"\r\n'
                f"Content-Type: {mime_type}\r\n"
                f"\r\n"
            ).encode("utf-8")
            + file_data
            + f"\r\n--{boundary}--\r\n".encode("utf-8")
        )

        headers = {
            "Authorization": self.token,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        }
        resp = self._request("POST", url, data=body, headers=headers)
        if isinstance(resp, dict):
            return resp.get("url", "") or resp.get("attachment", {}).get("url", "")
        return ""

    def list_uploaded_images(self) -> dict[str, str]:
        if not self.image_task_id:
            return {}
        try:
            url = f"{self.BASE_V2}/task/{self.image_task_id}"
            resp = self._get(url)
            attachments = resp.get("attachments", []) if isinstance(resp, dict) else []
            return {
                a.get("title", ""): a.get("url", "")
                for a in attachments
                if a.get("url")
            }
        except ClickUpAPIError as exc:
            log.warning("Could not list attachments for caching: %s", exc)
            return {}
