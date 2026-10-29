"""Private administration through database access, never a public HTTP route."""

import argparse
import asyncio
import json
import re
import sys
import uuid

from sqlalchemy import delete, func, select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader import feature_flags
from audioreader.db import SessionMaker, engine
from audioreader.models import FeatureFlag, User, UserFeatureFlag, UserIdentity


def flag_key(value: str) -> str:
    if not re.fullmatch(r"[a-z][a-z0-9_]{0,99}", value):
        raise argparse.ArgumentTypeError("Use a lowercase flag key, with letters, digits and underscores (max 100).")
    return value


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="List flag definitions and defaults")
    create = commands.add_parser("create", help="Create a flag (disabled by default)")
    create.add_argument("key", type=flag_key)
    create.add_argument("--description", required=True)
    default = commands.add_parser("set-default", help="Change the default for every account without an override")
    default.add_argument("key", type=flag_key)
    default.add_argument("value", choices=["on", "off"])
    for name in ("set-user", "reset-user", "show-user"):
        command = commands.add_parser(
            name,
            help={
                "set-user": "Set a per-account override",
                "reset-user": "Remove an override and follow the default",
                "show-user": "Show evaluated flags and overrides for one account",
            }[name],
        )
        if name != "show-user":
            command.add_argument("key", type=flag_key)
        if name == "set-user":
            command.add_argument("value", choices=["on", "off"])
        account = command.add_mutually_exclusive_group(required=True)
        account.add_argument("--user-id", type=uuid.UUID)
        account.add_argument("--email", help="Resolve a verified linked Apple/Google identity, never profile email")
    return root


async def resolve_user(session: AsyncSession, args: argparse.Namespace) -> User:
    if args.user_id is not None:
        user = await session.get(User, args.user_id)
        if user is None:
            raise ValueError("Account not found.")
        return user
    ids = list(
        await session.scalars(
            select(UserIdentity.user_id)
            .where(
                UserIdentity.provider.in_(["apple", "google"]),
                func.lower(UserIdentity.email) == args.email.strip().lower(),
            )
            .distinct()
        )
    )
    if not ids:
        raise ValueError("No account has that verified linked email.")
    if len(ids) != 1:
        raise ValueError("That email matches multiple accounts. Use --user-id to choose explicitly.")
    return await session.get_one(User, ids[0])


async def execute(session: AsyncSession, args: argparse.Namespace) -> object:
    """The caller owns the transaction; failures never commit partial changes."""
    if args.command == "list":
        return [
            {"key": flag.key, "description": flag.description, "default_enabled": flag.default_enabled}
            for flag in await session.scalars(select(FeatureFlag).order_by(FeatureFlag.key))
        ]
    if args.command == "create":
        if await session.get(FeatureFlag, args.key) is not None:
            raise ValueError("Flag already exists. Use set-default to change its default.")
        if not args.description.strip():
            raise ValueError("Description must not be empty.")
        session.add(FeatureFlag(key=args.key, description=args.description.strip(), default_enabled=False))
        await session.flush()
        return {"key": args.key, "default_enabled": False}
    if args.command == "show-user":
        user = await resolve_user(session, args)
        overrides = {
            row.flag_key: row.enabled
            for row in await session.scalars(
                select(UserFeatureFlag).where(UserFeatureFlag.user_id == user.id).order_by(UserFeatureFlag.flag_key)
            )
        }
        return {
            "user_id": str(user.id),
            "features": await feature_flags.for_user(session, user),
            "overrides": overrides,
        }
    # Serialise concurrent admin writes for a flag, including its composite-key
    # overrides. A typo must never silently create a new flag or grant access.
    flag = await session.scalar(select(FeatureFlag).where(FeatureFlag.key == args.key).with_for_update())
    if flag is None:
        raise ValueError("Unknown flag. Create it first.")
    if args.command == "set-default":
        flag.default_enabled = args.value == "on"
        return {"key": flag.key, "default_enabled": flag.default_enabled}
    user = await resolve_user(session, args)
    if args.command == "reset-user":
        await session.execute(
            delete(UserFeatureFlag).where(UserFeatureFlag.user_id == user.id, UserFeatureFlag.flag_key == flag.key)
        )
    else:
        override = await session.get(UserFeatureFlag, (user.id, flag.key))
        if override is None:
            session.add(UserFeatureFlag(user_id=user.id, flag_key=flag.key, enabled=args.value == "on"))
        else:
            override.enabled = args.value == "on"
    await session.flush()
    return {"user_id": str(user.id), "key": flag.key, "enabled": await feature_flags.enabled(session, user, flag.key)}


async def run(args: argparse.Namespace) -> object:
    try:
        async with SessionMaker.begin() as session:
            return await execute(session, args)
    finally:
        await engine.dispose()


def main() -> int:
    args = parser().parse_args()
    try:
        result = asyncio.run(run(args))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except SQLAlchemyError:
        # Connection URLs and bound values can contain secrets; omit traceback.
        print("Database operation failed; check database access and apply migrations first.", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
