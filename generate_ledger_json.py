import httpx
import hashlib
import base58
from pathlib import Path
import json
from dataclasses import dataclass

url = "http://localhost:5005"
devnet_url = "https://s.devnet.rippletest.net:51234"

wallet_propose = { "method": "wallet_propose"}
accounts = []
default_balance = 100_000_000000 # 100k XRP
NUM_ACCOUNTS = 3
ACCOUNTS_FILE = accounts_info_file = Path("accounts.json")
ledger_template_file = Path("ledger_template.json")
ledger_file_json = Path("ledger.json")

amendments = Path("amendments.json")
@dataclass
class Amendment:
    name: str
    index: str
    enabled: bool
    obsolete: bool

def read_amendments_from_network(network: str=devnet_url):
    feature_response = httpx.post(devnet_url, json={"method": "feature"})
    result = feature_response.json()['result']
    amendments = result["features"]
    amendment_list = []
    # amendments = {"enabled":[], "disabled": [], "obsolete": []}
    for amendment_hash, info in amendments.items():
        name = info["name"]
        supported = info["supported"]
        amendment_list.append(
            Amendment(
                name=info["name"],
                index=amendment_hash,
                enabled=info["enabled"],
                obsolete=info.get("obsolete", False),
            )
        )
    return amendment_list

def compute_account_index(account_id: str) -> str:
    account_space_key = "0061" # 0x0061
    # hashlib.sha512(message).digest()[:32]
    account_id_hex = base58.b58decode_check(account_id, alphabet=base58.XRP_ALPHABET)[1:].hex().upper()
    message = hashlib.sha512(bytes.fromhex(account_space_key + account_id_hex))
    account_index = message.digest()[:32].hex().upper()
    return account_index

account_root_json = {
    # "Account": "",
    #"index": comput_account_index(account_id),
    "Balance": str(default_balance),
    "Flags": 0,
    "LedgerEntryType": "AccountRoot",
    "OwnerCount": 0,
    "PreviousTxnID": "32366162368956912E817EAD0710F10C0CF16432FC4C9E098D8A7BA4FD5DC0F0",
    "PreviousTxnLgrSeq": 4,
    "Sequence": 5,
}
account_roots = []

def generate_accounts_file(num_accounts: str=NUM_ACCOUNTS):
    accounts = []
    for i in range(num_accounts):
        res = httpx.post(url, json=wallet_propose)
        result  = res.json()
        address = result["result"]["account_id"]
        seed = result["result"]["master_seed"]
        # acccount_index = compute_account_index(address)
        accounts.append({"address": address, "seed": seed})
    with accounts_info_file.open("w", encoding="UTF-8") as a:
        json.dump(accounts, a, indent=2)

def read_accounts_from_file(accounts_file: str=ACCOUNTS_FILE):
    with accounts_file.open(encoding="UTF-8") as a:
        accounts = json.load(a)
    return accounts

def generate_accounts_list(accounts):
    account_roots = []
    for account in accounts:
        address = account["address"]
        account_index = compute_account_index(address)
        account_roots.append({"Account": address, "index": account_index, **account_root_json})
    return account_roots

# TODO: Generate the fee settings
# def generate_fee_settings():
#             {
#           "BaseFee": "a",
#           "Flags": 0,
#           "LedgerEntryType": "FeeSettings",
#           "ReferenceFeeUnits": 10,
#           "ReserveBase": 11000000,
#           "ReserveIncrement": 3000000,
#           "index": "4BC50C9B0D8515D3EAAE1E74B29A95804346C491EE1A95BF25E4AAB854A6A651"
#         },

def generate_ledger_file(accounts, amendments):
    with ledger_template_file.open(encoding="UTF-8") as ltf:
        ledger_file_template = json.load(ltf)
    pass
    ledger_file = ledger_file_template.copy()
    account_state = ledger_file_template["ledger"]["accountState"]
    new_account_state = []
    for state in account_state:
        if state["LedgerEntryType"] == "Amendments":
            amendments_state = state
            amendments_state["Amendments"] = amendments
            new_account_state.append(amendments_state)
        else:
            new_account_state.append(state)
    pass
    for a in accounts:
        new_account_state.append(a)
            # f["Amendments"] = amendments

    ledger_file["ledger"].update(accountState=new_account_state)
    pass

    # ledger_file = { **ledger_
    # }
    pass
    # amendments = account_state["Amendments"]
   # account_state = { *accounts, {"Amendments": amendments}, **account_state}
    with ledger_file_json.open("w", encoding="UTF-8") as lf:
         json.dump(ledger_file, lf, indent=2)



# for i in range(num_accounts):
#     res = httpx.post(url, json=wallet_propose)
#     result  = res.json()
#     address = result["result"]["account_id"]
#     seed = result["result"]["master_seed"]
#     acccount_index = compute_account_index(address)
#     accounts.append({"address": address, "seed": seed})
#     account_roots.append({"Account": address, "index": acccount_index, **account_root_json})

## Generate accounts
generate_accounts_file()
accounts = read_accounts_from_file(ACCOUNTS_FILE)
accounts_json = generate_accounts_list(accounts)
pass
## Handle amendments
amendments = [a.index for a in read_amendments_from_network() if a.enabled]

generate_ledger_file(accounts_json, amendments)
# print(json.dumps(account_roots))
