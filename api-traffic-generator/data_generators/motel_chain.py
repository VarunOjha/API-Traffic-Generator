import random, uuid
from faker import Faker

fake = Faker("en_US")

US_STATES = ["AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN","IA","KS","KY",
             "LA","ME","MD","MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ","NM","NY","NC","ND",
             "OH","OK","OR","PA","RI","SC","SD","TN","TX","UT","VT","VA","WA","WV","WI","WY"]

def motel_chain_payload():
    chain_owner = fake.last_name()
    brand_tag = random.choice(["Suites","Inns","Lodges","Residency","Boutique","Select"])
    chain_name = f"The {chain_owner}'s {brand_tag}"
    addr1 = f"{chain_name} {fake.street_name()}"

    payload = {
        "motelChainName": chain_name,
        "displayName": chain_name,
        "state": random.choice(US_STATES),
        "pincode": fake.postcode().replace(" ", "")[:10],
        "status": random.choice(["Active","Active","Active","Inactive"]),
        "address": {
            "addressLine1": addr1[:60],
            "addressLine2": f"{fake.city()}, {fake.state_abbr()}",
            "landmark": random.choice(["HEB","Walmart","Airport","Convention Center","Downtown"]),
            "addressName": random.choice(["HeadQuarters","Main Office","Corporate"]),
            "status": "Active",
        },
        "contactInfo": {
            "phoneNumber": fake.msisdn()[:10],
            "email": fake.company_email(),
            "contactName": f"{fake.first_name()} {fake.last_name()}",
            "contactPosition": random.choice(["CEO","COO","VP Ops","Director"]),
            "contactType": random.choice(["Executive","Operations","Owner"]),
            "contactDescription": fake.sentence(nb_words=8),
            "status": "Active",
        }
    }
    return payload
