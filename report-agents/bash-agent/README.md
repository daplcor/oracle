# Trusted Price Oracle

## Shell Reporting Agent

A reporter agent for the Oracle, written in pure Bash.

## Supported prices sources

- Exchanges:
  - TradeOgre
  - Binance
  - CoinEx
  - Kucoin
  - OKX
  - Bybit

- Aggregators:
  - Coinmarketcap
  - CoinGecko

## Prerequisites

- `jq` must be installed and available in the executable path. It is included in most Linux/Unix distributions.
- The `kda` tool (https://github.com/kadena-io/kda-tool/) must also be available in the executable path.
  The required nodes must be properly configured in `~/.config/kda/config.json`.

**Example configuration:**

```json
{"networks":{"testnet04":"https://api.testnet.chainweb.com",
             "mainnet01":"https://api.chainweb.com",
             "development":"https://dev-fi.bro.pink"}
}
```

## Configuration

Three files are required in the working directory:

- `gas.key`: Private key for the gas-paying account.
- `reporter.key`: Private key of the reporter, registered within the oracle.
- `reporter.json`: Configuration file with the following fields:

  - **network**: Kadena network (e.g., `mainnet01`, `testnet04`, etc.)
  - **chain**: Kadena chain ID (e.g., `0`, `1`, ...)
  - **oracle**: Name of the oracle module
  - **gas-payer**: Account name responsible for gas payment
  - **gas-key**: Public key of the gas-payer (must match `gas.key`)
  - **symbol**: Asset symbol to report (e.g., `KDA`, `BTC`)
  - **reporter**: Name of the registered reporter within the oracle
  - **reporter-key**: Public key of the reporter (must match `reporter.key`)
  - **source**: One of the following data sources:
    - `tradeogre`
    - `binance`
    - `coinex`
    - `kucoin`
    - `okx`
    - `bybit`
    - `coinmarketcap`
    - `coingecko`
  - **source-api-key**: API key, required **only** for `coinmarketcap` or `coingecko`

## Running the Agent

Make sure the script is executable and that all required configuration files are present in the working directory:

```sh
./oracle_reporter.sh
```

It is recommended to run the script using a daemon manager such as **systemd** for improved reliability and automation.