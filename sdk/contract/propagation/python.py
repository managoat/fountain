import json
import os
from pathlib import Path
from fountain import Fountain, FountainError

fixture = json.loads(Path(__file__).with_name("fixture.json").read_text())
client = Fountain(base_url=os.environ["FOUNTAIN_BASE_URL"], api_key="fixture")
try:
    client.run_request(fixture["request"], timeout=5, collect_events=True).result()
except FountainError as error:
    assert error.status == 422 and error.code == "fixture_stop", error
else:
    raise AssertionError("fixture create should stop the run")
assert client.request("GET", "/api/conversations/c1") == {"data": fixture["response"]}
