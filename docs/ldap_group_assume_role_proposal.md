# LDAP Group-Based Role Assumption — Design Proposal

## Background

NooBaa supports `AssumeRoleWithWebIdentity` for LDAP users, where a user sends a JWT token containing their LDAP credentials to obtain temporary S3 credentials scoped to a role. Currently, any authenticated LDAP user can assume a role — there is no mechanism to restrict assumption based on LDAP group membership or any specific attribute.

This proposal adds group-based access control to the `AssumeRoleWithWebIdentity` flow, allowing administrators to configure roles that only specific LDAP groups or departments can assume.

---

## Current Flow

```
1. Client sends HTTP POST to STS:
      Action=AssumeRoleWithWebIdentity
      RoleArn=arn:aws:sts::<access_key>:role/<role_name>
      WebIdentityToken=<JWT containing username + password>

2. NooBaa extracts username and password from the JWT token

3. NooBaa authenticates the user against LDAP
      → receives the user's DN (Distinguished Name)

4. NooBaa fetches the account and role_config from the role ARN

5. Temporary credentials are issued to the caller
```

**Out of scope:** Step 5 always succeeds for any authenticated LDAP user. The `assume_role_policy` inside `role_config` is never evaluated for the `AssumeRoleWithWebIdentity` operation.

---

## Proposed Flow

```
1. Client sends HTTP POST to STS:
      Action=AssumeRoleWithWebIdentity
      RoleArn=arn:aws:sts::<access_key>:role/<role_name>
      WebIdentityToken=<JWT containing username + password>

2. NooBaa extracts username and password from the JWT token

3. NooBaa authenticates the user against LDAP
      → receives the user's DN
      → additionally fetches: ou, memberOf attributes  [NEW]

4. NooBaa fetches the account + role_config (including assume_role_policy) from the role ARN

5. NooBaa evaluates the assume_role_policy against the user's LDAP attributes  [NEW]
      → True  : issue temporary credentials
      → False : return Access Denied
```

---

## Role Config Format

A role is configured by setting `role_config` on a NooBaa account. The account's `access_key` forms the role ARN:

```
arn:aws:sts::<account_access_key>:role/<role_name>
```

### Example 1 — Restrict by OU (Department)

Only users whose LDAP `ou` attribute equals `Delivering Crew` can assume this role.

```json
{
  "role_name": "RoleB",
  "assume_role_policy": {
    "version": "2012-10-17",
    "statement": [
      {
        "effect": "allow",
        "principal": ["*"],
        "action": ["sts:AssumeRoleWithWebIdentity"],
        "condition": {
          "StringEquals": {
            "ldap:ou": "Delivering Crew"
          }
        }
      }
    ]
  }
}
```

### Example 2 — Restrict by Group Membership

Only members of `ship_crew` or `admin_staff` LDAP groups can assume this role. The `ForAnyValue` operator means the user's `memberOf` list needs to contain at least one of the listed values.

```json
{
  "role_name": "RoleB",
  "assume_role_policy": {
    "version": "2012-10-17",
    "statement": [
      {
        "effect": "allow",
        "principal": ["*"],
        "action": ["sts:AssumeRoleWithWebIdentity"],
        "condition": {
          "ForAnyValue:StringEquals": {
            "ldap:memberOf": [
              "cn=ship_crew,ou=people,dc=planetexpress,dc=com",
              "cn=admin_staff,ou=people,dc=planetexpress,dc=com"
            ]
          }
        }
      }
    ]
  }
}
```

### Example 3 — Multiple Conditions (OU AND Group)

Both conditions must be satisfied. The user must be in the `Delivering Crew` OU **and** be a member of `ship_crew`.

All conditions within a single `condition` block are evaluated with **AND** logic — every condition must pass.

```json
{
  "role_name": "RoleB",
  "assume_role_policy": {
    "version": "2012-10-17",
    "statement": [
      {
        "effect": "allow",
        "principal": ["*"],
        "action": ["sts:AssumeRoleWithWebIdentity"],
        "condition": {
          "StringEquals": {
            "ldap:ou": "Delivering Crew"
          },
          "ForAnyValue:StringEquals": {
            "ldap:memberOf": [
              "cn=ship_crew,ou=people,dc=planetexpress,dc=com"
            ]
          }
        }
      }
    ]
  }
}
```

### Example 4 — OR Conditions (OU OR Group)

The user must be in the `Delivering Crew` OU **or** be a member of `ship_crew` — either one is sufficient.

```json
{
  "role_name": "RoleB",
  "assume_role_policy": {
    "version": "2012-10-17",
    "statement": [
      {
        "effect": "allow",
        "principal": ["*"],
        "action": ["sts:AssumeRoleWithWebIdentity"],
        "condition": {
          "StringEquals": {
            "ldap:ou": "Delivering Crew"
          }
        }
      },
      {
        "effect": "allow",
        "principal": ["*"],
        "action": ["sts:AssumeRoleWithWebIdentity"],
        "condition": {
          "ForAnyValue:StringEquals": {
            "ldap:memberOf": [
              "cn=ship_crew,ou=people,dc=planetexpress,dc=com"
            ]
          }
        }
      }
    ]
  }
}
```

---

## Condition Operators

| Operator | Use Case | Behaviour |
|---|---|---|
| `StringEquals` | Single-value LDAP attribute (e.g. `ou`) | Exact string match |
| `ForAnyValue:StringEquals` | Multi-value LDAP attribute (e.g. `memberOf`) | At least one value in the user's list must match a value in the policy list |

---

## Stage 1 — Wire Web Identity Through `has_assume_role_permission`

**Stage 1** routes `AssumeRoleWithWebIdentity` through the existing `has_assume_role_permission` check (action + principal only; LDAP group/OU `condition` blocks are a later stage). Remove the early return `if (req.op_name !== 'post_assume_role') return;` in `authorize_request_policy` (`src/endpoint/sts/sts_rest.js`).

Example role config:

```json
{
  "role_name": "ldap_user",
  "assume_role_policy": {
    "version": "2012-10-17",
    "statement": [
      {
        "effect": "allow",
        "action": ["sts:AssumeRoleWithWebIdentity"],
        "principal": ["*"]
      }
    ]
  }
}
```

---

## Stage 2 — Evaluate LDAP `condition` Blocks

**Goal:** Evaluate `assume_role_policy` `condition` blocks (`ldap:ou`, `ldap:memberOf`) during `AssumeRoleWithWebIdentity`, using the role config examples above (Examples 1–4).

**Prerequisite:** Stage 1 must be in place — Web Identity already flows through `has_assume_role_permission` for action + principal.

### Why reorder?

In sts_rest.js, authorize_request(), LDAP user details are required before authorize_request_policy(). Hence, reordering is required ie for Web Identity LDAP auth will be moved to authorize phase.

### Request pipeline (Stage 2)

```
AssumeRole (unchanged):
  load_requesting_account → authorize_request_account → authorize_request_policy → handler

AssumeRoleWithWebIdentity:
  load_requesting_account → authorize_request_account → authenticate_web_identity → authorize_request_policy → handler
                              (same)                    (NEW)                      (+ conditions)              (same call)
```

---
### File changes
#### 1. `src/endpoint/sts/sts_rest.js`

Add LDAP auth before policy, Web Identity only:

```javascript
async function authorize_request(req) {
    await req.sts_sdk.load_requesting_account(req);
    req.sts_sdk.authorize_request_account(req);

    if (req.op_name === 'post_assume_role_with_web_identity') {
        await req.sts_sdk.authenticate_web_identity(req);
    }

    await authorize_request_policy(req);
}
```

- In `authorize_request_policy`, pass LDAP identity into the policy check.

- Extend `has_assume_role_permission` / `_is_statements_fit` to evaluate `statement.condition` when `ldap_identity` is present:
- Supported keys format: `ldap:*` e.g. `ldap:ou` `ldap:memberOf`
- Supported operators: `StringEquals`, `ForAnyValue:StringEquals` (see Condition Operators table above)
- Conditions within one `condition` block: **AND**
- Multiple allow statements with conditions: **OR** (existing statement-matching behaviour)

If a statement has no `condition` block, behaviour is unchanged (action + principal only).

#### 2. `src/sdk/sts_sdk.js`

Extract JWT verify + LDAP bind from `get_assumed_ldap_user` into `authenticate_web_identity(req)`:

- Cache result on the SDK instance: `this.ldap_identity = { dn, ou, memberOf }`
- If already cached, return immediately (no second LDAP bind)
- `get_assumed_ldap_user(req)` gets LDAP details first, then `_assume_role` — handler code unchanged

#### 3. `src/util/ldap_client.js`

Extend `authenticate(user, password)` to fetch and return LDAP attributes needed for policy:

returns `dn`, `ou` and `memberOf` (or any other required fields)

#### 4. Optional — config-time validation

Reject malformed `condition` blocks when a role is created/updated (fail fast at CLI/API time, not at first STS call)
