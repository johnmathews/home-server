# /opt/key_server/main.py

from fastapi import FastAPI, Request, HTTPException
from typing import Dict

app = FastAPI()

SECRET_TOKEN = "supersecrettoken"

@app.get("/unlock", response_model=Dict[str, str])
async def unlock(request: Request):
    auth = request.headers.get("Authorization", "")
    if auth != f"Bearer {SECRET_TOKEN}":
        raise HTTPException(status_code=403, detail="Unauthorized")
    return {
        "tank/media": "KEY_FOR_MEDIA",
        "tank/photos": "KEY_FOR_PHOTOS"
    }
