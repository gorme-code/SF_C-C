#!/usr/bin/env python3
"""
Provision a Contact with district and/or school access for the Calendars & Closures app.

Always creates:
  - 1 District Contact_Role  (Contact → District Account)
    → marks the user as a district admin; list_closures() shows all district schools

Optionally creates School Contact_Roles for specific schools (--schools):
  → those schools appear in the user's submission dropdown (get_schools())
  → omit --schools to give access to all district schools in the dropdown

Skips any Contact_Role that already exists (idempotent).

Auth: OAuth 2.0 client-credentials flow via environment variables:
  SF_CLIENT_ID, SF_CLIENT_SECRET, SF_INSTANCE_URL

Usage (district admin, submission dropdown = all schools):
  python scripts/provision_district_user.py "Paul Anderson" "Abbeville"

Usage (district admin, submission dropdown = specific schools only):
  python scripts/provision_district_user.py "Paul Anderson" "Abbeville" --schools "Westwood Elementary" "Abbeville County Career Center"
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
    client_id = get_env("SF_CLIENT_ID")
    client_secret = get_env("SF_CLIENT_SECRET")
    instance_url = get_env("SF_INSTANCE_URL").rstrip("/")

    resp = requests.post(
        f"{instance_url}/services/oauth2/token",
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
    returned_instance = payload.get("instance_url", instance_url)
    return Salesforce(instance_url=returned_instance, session_id=payload["access_token"])


def query_one(sf: Salesforce, soql: str) -> dict | None:
    result = sf.query(soql)
    records = result.get("records", [])
    return records[0] if records else None


def role_exists(sf: Salesforce, contact_id: str, account_id: str, role_type: str) -> bool:
    """Return True if an active Contact_Role already links this Contact + Account + Type."""
    rec = query_one(
        sf,
        "SELECT Id FROM Contact_Role__c "
        f"WHERE Contact__c = '{contact_id}' "
        f"AND Account__c = '{account_id}' "
        f"AND Type__c = '{role_type}' "
        "AND isActive__c = true "
        "LIMIT 1",
    )
    return rec is not None


_ROLE_BY_TYPE = {
    "District": "District User",
    "School": "Principal",
    "Program": "Program Administrator",
    "Other": "Vendor",
}


def create_role(sf: Salesforce, contact_id: str, account_id: str, role_type: str) -> str:
    result = sf.Contact_Role__c.create({
        "Contact__c": contact_id,
        "Account__c": account_id,
        "Type__c": role_type,
        "Role__c": _ROLE_BY_TYPE[role_type],
        "isActive__c": True,
    })
    if not result.get("success"):
        sys.exit(f"ERROR: failed to create {role_type} Contact_Role: {result}")
    return result["id"]


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(
            "Usage: python provision_district_user.py \"<Contact Name>\" \"<District Name>\" "
            "[--schools \"School 1\" \"School 2\" ...]"
        )

    contact_name = sys.argv[1]
    district_name = sys.argv[2]

    # Parse optional --schools list
    specific_schools: list[str] = []
    if "--schools" in sys.argv:
        idx = sys.argv.index("--schools")
        specific_schools = sys.argv[idx + 1:]
        if not specific_schools:
            sys.exit("ERROR: --schools requires at least one school name.")

    sf = authenticate()
    print(f"Authenticated to Salesforce.\n")

    # --- Find the Contact ---
    name_parts = contact_name.strip().split(None, 1)
    if len(name_parts) == 2:
        first, last = name_parts
        contact = query_one(
            sf,
            f"SELECT Id, Name, Email FROM Contact "
            f"WHERE FirstName = '{first}' AND LastName = '{last}' LIMIT 1",
        )
    else:
        contact = query_one(
            sf,
            f"SELECT Id, Name, Email FROM Contact "
            f"WHERE Name = '{contact_name}' LIMIT 1",
        )

    if not contact:
        sys.exit(f"ERROR: Contact '{contact_name}' not found in Salesforce.")
    contact_id = contact["Id"]
    print(f"Contact:  {contact['Name']} ({contact.get('Email', 'no email')})  {contact_id}")

    # --- Find the District Account ---
    safe_district = district_name.replace("'", r"\'")
    district = query_one(
        sf,
        "SELECT Id, Name FROM Account "
        f"WHERE RecordType.DeveloperName = 'District' AND Name LIKE '%{safe_district}%' LIMIT 1",
    )
    if not district:
        sys.exit(f"ERROR: District account matching '{district_name}' not found.")
    district_id = district["Id"]
    print(f"District: {district['Name']}  {district_id}")

    # --- District Contact_Role ---
    print(f"\nProvisioning District Contact_Role...")
    if role_exists(sf, contact_id, district_id, "District"):
        print(f"  [skip] District role already exists.")
    else:
        rid = create_role(sf, contact_id, district_id, "District")
        print(f"  [created] {rid}")

    # --- Resolve all district schools and existing School Contact_Roles ---
    all_schools_result = sf.query(
        "SELECT Id, Name FROM Account "
        f"WHERE RecordType.DeveloperName = 'School' AND ParentId = '{district_id}' "
        "ORDER BY Name"
    )
    all_schools = all_schools_result.get("records", [])

    existing_school_roles_result = sf.query(
        "SELECT Id, Account__c, Account__r.Name FROM Contact_Role__c "
        f"WHERE Contact__c = '{contact_id}' AND Type__c = 'School' AND isActive__c = true"
    )
    existing_school_roles = existing_school_roles_result.get("records", [])

    # Resolve the target school Account IDs from the --schools names
    target_account_ids: set[str] = set()
    if specific_schools:
        print(f"\nProvisioning School Contact_Roles for {len(specific_schools)} school(s)...")
        for target_name in specific_schools:
            match = next(
                (s for s in all_schools if target_name.lower() in s["Name"].lower()),
                None,
            )
            if not match:
                print(f"  [error]   '{target_name}' — no matching school found in {district['Name']}")
                continue
            target_account_ids.add(match["Id"])
            if any(r["Account__c"] == match["Id"] for r in existing_school_roles):
                print(f"  [skip]    {match['Name']}")
            else:
                rid = create_role(sf, contact_id, match["Id"], "School")
                print(f"  [created] {match['Name']}  {rid}")
    else:
        print(f"\nNo --schools specified: {contact['Name']} will see all district schools "
              f"in the submission dropdown.")

    # --- Deactivate any School Contact_Roles not in the target list ---
    extras = [r for r in existing_school_roles if r["Account__c"] not in target_account_ids]
    if extras:
        print(f"\nDeactivating {len(extras)} extra School Contact_Role(s)...")
        for r in extras:
            school_name = (r.get("Account__r") or {}).get("Name", r["Account__c"])
            sf.Contact_Role__c.update(r["Id"], {"isActive__c": False})
            print(f"  [deactivated] {school_name}  {r['Id']}")

    total_roles = 1 + len(target_account_ids)
    print(f"\nDone. {contact['Name']} has {total_roles} active role(s): "
          f"1 District + {len(target_account_ids)} School. "
          f"Oversees all closures district-wide in {district['Name']}.")


if __name__ == "__main__":
    main()
