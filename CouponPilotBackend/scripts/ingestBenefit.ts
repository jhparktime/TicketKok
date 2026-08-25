import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import { submitOfficialBenefitCandidate, type CalculatorBenefitRule, type OfficialProductPrice } from "../src/benefitRag.js";

const args = process.argv.slice(2);
const value = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const file = value("--file");
const title = value("--title");
const provider = value("--provider");
const sourceURL = value("--source-url");
const checkedAt = value("--checked-at");
const staleAfter = value("--stale-after");
const reviewer = value("--reviewer");
const version = value("--version");
const license = value("--license");
if (!file || !title || !provider || !sourceURL || !checkedAt || !staleAfter || !reviewer || !version || !license) {
  throw new Error("Usage: npm run ingest:benefit -- --file <official.md> --title <title> --provider <provider> --source-url <https://official-url> --checked-at YYYY-MM-DD --stale-after YYYY-MM-DD --reviewer <name> --version <immutable-version> --license <reviewed-rights-decision> [--effective-from YYYY-MM-DD --effective-to YYYY-MM-DD --limitations condition1,condition2 --kind carrier|card --percent 10 --fixed 0 --max 3000 --min 10000 --combinable true --grades VIP,VVIP --stores 스타벅스 --requires-available true --card-product-id shinhancard-mr-life --requires-previous-spend true --hours 21,22,23,0 --product-name <exact-product> --price-won <positive-integer> --product-aliases alias1,alias2]");
}
const kind = value("--kind");
if (kind && kind !== "carrier" && kind !== "card") throw new Error("--kind must be carrier or card");
const commaValues = (name: string) => value(name)?.split(",").map((item) => item.trim()).filter(Boolean);
const numberValue = (name: string, minimum: number, maximum: number) => {
  const raw = value(name);
  if (raw === undefined) return undefined;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < minimum || parsed > maximum) throw new Error(`${name} must be between ${minimum} and ${maximum}`);
  return parsed;
};
const booleanValue = (name: string, required = false) => {
  const raw = value(name);
  if (raw === undefined && !required) return undefined;
  if (raw !== "true" && raw !== "false") throw new Error(`${name} must be true or false`);
  return raw === "true";
};
const hours = commaValues("--hours")?.map((raw) => {
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 23) throw new Error("--hours must contain integers from 0 through 23");
  return parsed;
});
const rule: CalculatorBenefitRule | undefined = kind === "carrier" || kind === "card" ? {
  provider, appliesTo: kind,
  discountPercent: numberValue("--percent", 0, 100),
  fixedDiscount: numberValue("--fixed", 0, 1_000_000),
  maximumDiscount: numberValue("--max", 0, 1_000_000),
  minimumOrderAmount: numberValue("--min", 0, 1_000_000),
  combinableWithCoupon: booleanValue("--combinable", true),
  eligibleGrades: commaValues("--grades"),
  eligibleStoreKeywords: commaValues("--stores"),
  requiresAvailableThisMonth: booleanValue("--requires-available"),
  cardProductId: value("--card-product-id"),
  requiresPreviousMonthSpend: booleanValue("--requires-previous-spend"),
  eligibleHoursKST: hours
} : undefined;
const productName = value("--product-name");
const priceWon = numberValue("--price-won", 1, 1_000_000);
if ((productName && priceWon === undefined) || (!productName && priceWon !== undefined)) {
  throw new Error("--product-name and --price-won must be supplied together");
}
const productPrices: OfficialProductPrice[] | undefined = productName && priceWon !== undefined ? [{
  productName,
  priceWon,
  aliases: commaValues("--product-aliases")
}] : undefined;
const result = await submitOfficialBenefitCandidate({
  id: basename(file).replace(/\.[^.]+$/, "").replace(/[^a-zA-Z0-9-_]/g, "-"), title, provider, sourceURL,
  content: await readFile(file, "utf8"), rule, productPrices,
  governance: {
    // This command submits a reviewed snapshot. It cannot affect retrieval or Calculator
    // output until an independent reviewer runs approve:benefit.
    status: "reviewed",
    checkedAt,
    staleAfter,
    effectiveFrom: value("--effective-from"),
    effectiveTo: value("--effective-to"),
    version,
    reviewer,
    license,
    limitations: commaValues("--limitations") ?? []
  }
}, reviewer);
console.log(JSON.stringify({
  ...result,
  nextStep: "An independent reviewer must inspect sourceSnapshotObject and run approve:benefit."
}));
