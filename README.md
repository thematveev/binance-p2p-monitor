# Binance P2P Monitor 📊

Monitors **UAH/USDT** P2P prices on Binance every 30 seconds and saves them to a CSV file.

## Features

- Filters by **PrivatBank** and **Monobank** payment methods
- Minimum transaction amount: **500 UAH**
- Tracks top **BUY** and **SELL** prices + spread
- Logs to console (`INFO`) and rotating log file (`DEBUG`)
- CSV output: `binance_p2p_uah_usdt.csv`

## Requirements

```bash
pip install requests
```

## Usage

```bash
python binance_p2p_monitor.py
```

## CSV Output

| Column | Description |
|---|---|
| `time` | Timestamp of snapshot |
| `sell_price_uah` | Cheapest price to **buy** USDT (UAH) |
| `buy_price_uah` | Best price when **selling** USDT (UAH) |

## Configuration

Edit the constants at the top of the script:

```python
PAY_TYPES    = ["PrivatBank", "Monobank"]  # payment method filter
TRANS_AMOUNT = "500"                        # minimum UAH amount
INTERVAL     = 30                           # poll interval in seconds
```

## Log Files

- `binance_p2p_monitor.log` — rotating log, max 5 MB, 3 backups kept
