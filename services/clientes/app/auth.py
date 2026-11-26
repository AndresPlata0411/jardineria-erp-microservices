import os

import jwt
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

SECRET = os.environ["JWT_SECRET"]
ALGO = "HS256"
_bearer = HTTPBearer(auto_error=False)


def current_user(request: Request, cred: HTTPAuthorizationCredentials = Depends(_bearer)) -> dict:
    if cred is None:
        raise HTTPException(401, "Falta el token")
    try:
        payload = jwt.decode(cred.credentials, SECRET, algorithms=[ALGO])
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "Token expirado")
    except jwt.InvalidTokenError:
        raise HTTPException(401, "Token invalido")
    request.state.user = payload["sub"]
    return payload


def require_admin(user: dict = Depends(current_user)) -> dict:
    if user.get("rol") != "admin":
        raise HTTPException(403, "Requiere rol admin")
    return user
