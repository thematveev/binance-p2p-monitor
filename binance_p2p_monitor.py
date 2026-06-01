"""
Binance P2P UAH/USDT Price Monitor
- Filters: PrivatBank + Monobank payment methods
- Minimum amount: 500 UAH
- Polls every 30 seconds, stores top BUY and SELL prices to CSV
- Logs to both console and file (binance_p2p_monitor.log)
"""

import requests
import csv
import time
import os
import logging
from datetime import datetime

CSV_FILE = "binance_p2p_uah_usdt.csv"
LOG_FILE = "binance_p2p_monitor.log"
INTERVAL = 30  # seconds

API_URL = "https://p2p.binance.com/bapi/c2c/v2/friendly/c2c/adv/search"

HEADERS = {
    "Accept": "*/*",
    "Accept-Encoding": "gzip, deflate, br",
    "Accept-Language": "en-US,en;q=0.9",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
    "Content-Type": "application/json",
    "Host": "p2p.binance.com",
    "Origin": "https://p2p.binance.com",
    "Pragma": "no-cache",
    "Referer": "https://p2p.binance.com/",
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
}

PAY_TYPES = ["PrivatBank", "Monobank"]
TRANS_AMOUNT = "500"


# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

def setup_logging() -> logging.Logger:
    logger = logging.getLogger("p2p_monitor")
    logger.setLevel(logging.DEBUG)

    fmt = logging.Formatter(
        fmt="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # Console handler — INFO and above
    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    console.setFormatter(fmt)

    # File handler — DEBUG and above (rotating every 5 MB, keep 3 backups)
    from logging.handlers import RotatingFileHandler
    file_handler = RotatingFileHandler(
        LOG_FILE, maxBytes=5 * 1024 * 1024, backupCount=3, encoding="utf-8"
    )
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(fmt)

    logger.addHandler(console)
    logger.addHandler(file_handler)
    return logger


log = setup_logging()


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

def build_payload(trade_type: str, rows: int = 1) -> dict:
    return {
        "asset": "USDT",
        "fiat": "UAH",
        "merchantCheck": False,
        "page": 1,
        "payTypes": PAY_TYPES,
        "publisherType": None,
        "rows": rows,
        "tradeType": trade_type,
        "transAmount": TRANS_AMOUNT,
        "countries": [],
        "proMerchantAds": False,
        "shieldMerchantAds": False,
        "filterType": "all",
        "periods": [],
        "additionalKycVerifyFilter": 0,
        "classifies": ["mass", "profession", "fiat_trade"],
    }


def get_top_price(trade_type: str) -> float | None:
    payload = build_payload(trade_type, rows=1)
    log.debug("Requesting %s ads | payTypes=%s | transAmount=%s UAH", trade_type, PAY_TYPES, TRANS_AMOUNT)
    try:
        resp = requests.post(API_URL, headers=HEADERS, json=payload, timeout=15)
        log.debug("Response status: %s | elapsed: %s", resp.status_code, resp.elapsed)
        resp.raise_for_status()
        data = resp.json()
        ads = data.get("data", [])
        if ads:
            price = float(ads[0]["adv"]["price"])
            log.debug("%s top price: %s UAH (advertiser: %s)", trade_type, price, ads[0]["advertiser"].get("nickName", "N/A"))
            return price
        else:
            log.warning("No ads returned for tradeType=%s — filters may be too strict", trade_type)
    except requests.exceptions.Timeout:
        log.error("Request timed out for tradeType=%s", trade_type)
    except requests.exceptions.HTTPError as e:
        log.error("HTTP error for tradeType=%s: %s", trade_type, e)
    except requests.exceptions.RequestException as e:
        log.error("Network error for tradeType=%s: %s", trade_type, e)
    except (KeyError, ValueError) as e:
        log.error("Failed to parse response for tradeType=%s: %s", trade_type, e)
    return None


# ---------------------------------------------------------------------------
# CSV
# ---------------------------------------------------------------------------

def init_csv():
    if not os.path.exists(CSV_FILE):
        with open(CSV_FILE, "w", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow(["time", "sell_price_uah", "buy_price_uah"])
        log.info("Created CSV: %s", os.path.abspath(CSV_FILE))
    else:
        log.info("Appending to existing CSV: %s", os.path.abspath(CSV_FILE))


def append_row(timestamp: str, sell_price, buy_price):
    with open(CSV_FILE, "a", newline="", encoding="utf-8") as f:
        csv.writer(f).writerow([timestamp, sell_price, buy_price])
    log.debug("CSV row written: %s | sell=%s | buy=%s", timestamp, sell_price, buy_price)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main():
    log.info("=" * 55)
    log.info("  Binance P2P UAH/USDT Monitor started")
    log.info("  Payment methods : %s", ", ".join(PAY_TYPES))
    log.info("  Min amount      : %s UAH", TRANS_AMOUNT)
    log.info("  Interval        : %ss", INTERVAL)
    log.info("  Log file        : %s", os.path.abspath(LOG_FILE))
    log.info("=" * 55)

    init_csv()

    poll = 0
    while True:
        poll += 1
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log.debug("--- Poll #%d start ---", poll)

        sell_price = get_top_price("SELL")
        buy_price  = get_top_price("BUY")

        if sell_price is not None and buy_price is not None:
            spread = round(sell_price - buy_price, 4)
            log.info(
                "Poll #%d | BUY usdt @ %s UAH | SELL usdt @ %s UAH | Spread: %s UAH",
                poll, buy_price, sell_price, spread,
            )
        else:
            log.warning("Poll #%d | Incomplete data — sell=%s buy=%s", poll, sell_price, buy_price)

        append_row(now, sell_price, buy_price)

        log.debug("Sleeping %ss until next poll...", INTERVAL)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log.info("Monitor stopped by user (KeyboardInterrupt).")
