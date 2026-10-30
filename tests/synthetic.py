"""Synthetic SEC 'companyfacts' documents for fictional companies (never real data)."""
from __future__ import annotations

YEARS = [2020, 2021, 2022, 2023, 2024]


def _flow(tag, series, years, unit="USD"):
    facts = [{"start": f"{y}-01-01", "end": f"{y}-12-31", "val": v, "form": "10-K",
              "filed": f"{y + 1}-02-15", "accn": f"ACC-{y + 1}"} for y, v in zip(years, series)]
    return tag, {"units": {unit: facts}}


def _inst(tag, series, years, unit="USD"):
    facts = [{"end": f"{y}-12-31", "val": v, "form": "10-K",
              "filed": f"{y + 1}-02-15", "accn": f"ACC-{y + 1}"} for y, v in zip(years, series)]
    return tag, {"units": {unit: facts}}


def strong(years=YEARS):
    """Every Piotroski signal improves every year -> F-score 9."""
    n = range(len(YEARS))
    sel = [i for i, y in enumerate(YEARS) if y in years]
    pick = lambda xs: [xs[i] for i in sel]
    revenue = [1000 * 1.10 ** i for i in n]
    cost = [600 * 1.05 ** i for i in n]
    ni = [100 + 30 * i for i in n]
    assets = [1000 + 50 * i for i in n]
    equity = [600 + 60 * i for i in n]
    d = dict([
        _flow("Revenues", pick(revenue), years),
        _flow("CostOfRevenue", pick(cost), years),
        _flow("OperatingIncomeLoss", pick([x * 1.3 for x in ni]), years),
        _flow("NetIncomeLoss", pick(ni), years),
        _flow("WeightedAverageNumberOfDilutedSharesOutstanding", pick([100 - i for i in n]), years, "shares"),
        _flow("NetCashProvidedByUsedInOperatingActivities", pick([x + 20 for x in ni]), years),
        _flow("PaymentsToAcquirePropertyPlantAndEquipment", pick([40] * 5), years),
        _inst("Assets", pick(assets), years),
        _inst("AssetsCurrent", pick([400 + 40 * i for i in n]), years),
        _inst("LiabilitiesCurrent", pick([200] * 5), years),
        _inst("Liabilities", pick([a - e for a, e in zip(assets, equity)]), years),
        _inst("LongTermDebtNoncurrent", pick([300 - 30 * i for i in n]), years),
        _inst("StockholdersEquity", pick(equity), years),
        _inst("RetainedEarningsAccumulatedDeficit", pick([300 + 50 * i for i in n]), years),
    ])
    return d


def weak():
    """Everything deteriorates -> F-score 0, Altman in distress."""
    n = range(5)
    assets = [1000 + 100 * i for i in n]
    equity = [500 - 60 * i for i in n]
    ni = [50 - 30 * i for i in n]
    return dict([
        _flow("Revenues", [1000 * 0.95 ** i for i in n], YEARS),
        _flow("CostOfRevenue", [600] * 5, YEARS),
        _flow("OperatingIncomeLoss", [x * 1.3 for x in ni], YEARS),
        _flow("NetIncomeLoss", ni, YEARS),
        _flow("WeightedAverageNumberOfDilutedSharesOutstanding", [100 + 5 * i for i in n], YEARS, "shares"),
        _flow("NetCashProvidedByUsedInOperatingActivities", [x - 10 for x in ni], YEARS),
        _flow("PaymentsToAcquirePropertyPlantAndEquipment", [40] * 5, YEARS),
        _inst("Assets", assets, YEARS),
        _inst("AssetsCurrent", [300] * 5, YEARS),
        _inst("LiabilitiesCurrent", [200 + 40 * i for i in n], YEARS),
        _inst("Liabilities", [a - e for a, e in zip(assets, equity)], YEARS),
        _inst("LongTermDebtNoncurrent", [300 + 40 * i for i in n], YEARS),
        _inst("StockholdersEquity", equity, YEARS),
        _inst("RetainedEarningsAccumulatedDeficit", [100 - 30 * i for i in n], YEARS),
    ])


def wrap(name: str, facts: dict) -> dict:
    return {"entityName": name, "facts": {"us-gaap": facts}}


def add_noise(facts: dict) -> dict:
    """Add rows that MUST be ignored or de-duplicated by the pipeline."""
    # a 10-Q fact (ignored by form filter)
    facts["Revenues"]["units"]["USD"].append(
        {"start": "2024-01-01", "end": "2024-03-31", "val": 9_999_999, "form": "10-Q",
         "filed": "2024-05-01", "accn": "ACC-Q1"})
    # a 3-month fact inside a 10-K (ignored by the 350-380 day rule)
    facts["Revenues"]["units"]["USD"].append(
        {"start": "2024-10-01", "end": "2024-12-31", "val": 8_888_888, "form": "10-K",
         "filed": "2025-02-15", "accn": "ACC-2025"})
    # a restated FY2023 value filed later -> must win over the original
    orig = [f for f in facts["NetIncomeLoss"]["units"]["USD"] if f["end"] == "2023-12-31"][0]
    facts["NetIncomeLoss"]["units"]["USD"].append({**orig, "val": orig["val"] + 1, "filed": "2025-02-15", "accn": "ACC-RESTATED"})
    return facts
