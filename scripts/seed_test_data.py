#!/usr/bin/env python3
"""
Seed test data into the Calendars & Closures Salesforce sandbox.

Creates:
  - 1 District Account
  - 3 School Accounts (children of the district)
  - 1 Contact linked to the district

Auth: OAuth 2.0 client-credentials flow. Reads from environment variables:
  SF_CLIENT_ID, SF_CLIENT_SECRET, SF_INSTANCE_URL
  (SF_INSTANCE_URL example: https://scde--devmemberc.sandbox.my.salesforce.com)

Requires: simple_salesforce, requests
  pip install simple-salesforce requests

Usage:
  export SF_CLIENT_ID=...
  export SF_CLIENT_SECRET=...
  export SF_INSTANCE_URL=https://scde--devmemberc.sandbox.my.salesforce.com
  python scripts/seed_test_data.py
"""

import os
import sys

import requests
from simple_salesforce import Salesforce


def get_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"ERROR: required environment variable {name} is not set.")
    return value


def authenticate() -> Salesforce:
    """Authenticate via the OAuth 2.0 client-credentials flow and return a Salesforce client."""
    client_id = get_env("SF_CLIENT_ID")
    client_secret = get_env("SF_CLIENT_SECRET")
    instance_url = get_env("SF_INSTANCE_URL").rstrip("/")

    token_url = f"{instance_url}/services/oauth2/token"
    resp = requests.post(
        token_url,
        data={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
        },
        timeout=30,
    )

    if resp.status_code != 200:
        sys.exit(f"ERROR: authentication failed ({resp.status_code}): {resp.text}")

    payload = resp.json()
    access_token = payload["access_token"]
    # token response instance_url omits the scheme path; prefer it but fall back to env
    returned_instance = payload.get("instance_url", instance_url)

    return Salesforce(instance_url=returned_instance, session_id=access_token)


def get_account_record_type_ids(sf: Salesforce) -> dict:
    """Return a map of Account RecordType DeveloperName -> Id."""
    result = sf.query(
        "SELECT Id, DeveloperName FROM RecordType "
        "WHERE SobjectType = 'Account'"
    )
    return {r["DeveloperName"]: r["Id"] for r in result["records"]}


def create_record(sf_object, fields: dict, label: str) -> str:
    result = sf_object.create(fields)
    if not result.get("success"):
        sys.exit(f"ERROR: failed to create {label}: {result}")
    return result["id"]


def main() -> None:
    sf = authenticate()
    print("Authenticated to Salesforce.\n")

    rt = get_account_record_type_ids(sf)
    district_rt = rt.get("District")
    school_rt = rt.get("School")
    if not district_rt:
        sys.exit("ERROR: Account record type 'District' not found in the org.")
    if not school_rt:
        sys.exit("ERROR: Account record type 'School' not found in the org.")

    # 1. District Account
    district_id = create_record(
        sf.Account,
        {"Name": "Seed Test District", "RecordTypeId": district_rt},
        "District Account",
    )
    print(f"District Account:  {district_id}")

    # 2. Three School Accounts (children of the district)
    school_ids = []
    for i in range(1, 4):
        sid = create_record(
            sf.Account,
            {
                "Name": f"Seed Test School {i}",
                "RecordTypeId": school_rt,
                "ParentId": district_id,
            },
            f"School Account {i}",
        )
        school_ids.append(sid)
        print(f"School Account {i}:  {sid}")

    # 3. Contact linked to the district
    contact_id = create_record(
        sf.Contact,
        {
            "FirstName": "Seed",
            "LastName": "District Contact",
            "AccountId": district_id,
            "Email": "seed.contact@example.com",
        },
        "Contact",
    )
    print(f"Contact:           {contact_id}")

    print("\n--- Summary (for use in subsequent tests) ---")
    print(f"DISTRICT_ID={district_id}")
    for i, sid in enumerate(school_ids, start=1):
        print(f"SCHOOL_{i}_ID={sid}")
    print(f"CONTACT_ID={contact_id}")


if __name__ == "__main__":
    main()
