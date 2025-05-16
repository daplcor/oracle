# Trusted Price Oracle

A reliable oracle system with multiple trusted reporters and median-based aggregation for Kadena blockchain.

## Overview

This oracle system provides reliable price data for various trading pairs through a network of trusted reporters. The design focuses on reliability and accuracy rather than decentralization, with the following key features:

- Multiple trusted reporters approved by administrators (OPS)
- Time-spread reporting with randomization to ensure even distribution
- Median-based aggregation of recent reports
- FIFO queue system to maintain only the most relevant reports
- Simple client interface for reading price data

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                       ADMIN OPERATIONS (OPS)                         │
├─────────────┬─────────────────────────────┬──────────────────────────┤
│             │                             │                          │
│ add-reporter│                       add-symbol                       │
│             │                             │                          │
└─────────────┼─────────────────────────────┼──────────────────────────┘
              │                             │
              ▼                             ▼
┌─────────────────────┐           ┌──────────────────────┐
│                     │           │                      │
│  Reporter Database  │           │   Symbol Database    │
│                     │           │                      │
└─────────────────────┘           └──────────────────────┘
              ▲                             ▲
              │                             │
┌─────────────┴─────────────────────────────┴───────────────────────────┐
│                      REPORTER OPERATIONS                              │
├─────────────────────────────────────────────────────────────────────┐ │
│                                                                     │ │
│                         submit-report                               │ │
│                              │                                      │ │
│                              ▼                                      │ │
│                 ┌──────────────────────────┐                        │ │
│                 │ 1. Validate symbol,      │                        │ │
│                 │    reporter & time       │                        │ │
│                 └────────────┬─────────────┘                        │ │
│                              │                                      │ │
│                              ▼                                      │ │
│                 ┌──────────────────────────┐                        │ │
│                 │ 2. Set next report time  │                        │ │
│                 │    with randomization    │                        │ │
│                 └────────────┬─────────────┘                        │ │
│                              │                                      │ │
│                              ▼                                      │ │
│                 ┌──────────────────────────┐                        │ │
│                 │ 3. Store the report      │◄───────────┐           │ │
│                 └────────────┬─────────────┘            │           │ │
│                              │                          │           │ │
│                              ▼                          │           │ │
│                 ┌──────────────────────────┐            │           │ │
│                 │ 4. Update recent reports │            │           │ │
│                 │    list (FIFO queue)     │            │           │ │
│                 └────────────┬─────────────┘            │           │ │
│                              │                          │           │ │
│                              ▼                          │           │ │
│                 ┌──────────────────────────┐            │           │ │
│                 │ 5. Calculate median &    │            │           │ │
│                 │    update oracle value   ├────────────┘           │ │
│                 └────────────┬─────────────┘                        │ │
│                              │                                      │ │
└──────────────────────────────┼──────────────────────────────────────┘ │
                               │                                        │
                               ▼                                        │
                    ┌────────────────────┐                              │
                    │  Oracle Database   │                              │
                    │                    │◄─────────────────────────────┘
                    └────────────────────┘
                               │
                               │
                               ▼
                    ┌────────────────────┐
                    │   Client Read      │
                    │   get-price()      │
                    └────────────────────┘
```

## Core Components

1. **Reporter Management**
   - Reporters are identified by string IDs
   - Each reporter has an associated guard for authentication
   - Reporters have scheduled reporting times with randomization
   - Reports can be submitted only after their assigned time

2. **Symbol Configuration**
   - Each trading pair has customizable parameters:
     - `avg-interval`: Base time between reports (e.g., 1 hour)
     - `max-deviation`: Maximum random time deviation (e.g., ±15 minutes)
     - `aggregation-count`: Number of recent reports to use for median calculation

3. **Report Processing**
   - Reports are stored with unique IDs
   - Recent reports are tracked in a FIFO queue for each symbol
   - Queue size is determined by the symbol's aggregation count
   - Oldest reports are automatically dropped when the queue is full

4. **Oracle Value Calculation**
   - Median value is calculated from the recent reports
   - For even number of reports, med* is used (average of middle values)
   - For odd number of reports, med is used (middle value)
   - Oracle is automatically updated after each report submission

## Contract Flow

The oracle operates through a sequence of operations:

1. **Initialization** - Tables are created during contract deployment
2. **Admin Setup** - OPS adds reporters and configures symbols
3. **Report Submission** - Reporters submit price data according to their schedule
4. **Oracle Updates** - The contract automatically updates the oracle value on each report
5. **Client Access** - External contracts read the current price data

### Detailed Flow:

```
Reporter → submit-report → verify active status → check time constraints → store report
                                                                        → update recent reports list
                                                                        → calculate median
                                                                        → update oracle value

Client → get-price → retrieve current price and timestamp
```

## Key Functions

### Governance Functions

#### `add-reporter`

Add a new trusted reporter to the system.

```
(add-reporter "reporter1" "Exchange A Reporter" (read-keyset 'reporter-ks))
```

**Parameters:**
- `reporter`: String identifier for the reporter
- `description`: Human-readable description
- `g`: Guard for report authentication

**Returns:** Success message string

#### `add-symbol`

Add a new trading pair to the oracle.

```
(add-symbol "KDA/USD" 3600.0 900.0 5)
```

**Parameters:**
- `symbol`: String identifier for the trading pair
- `avg-interval`: Average time between reports in seconds
- `max-deviation`: Maximum time deviation for randomization
- `aggregation-count`: Number of reports to use for aggregation

**Returns:** Success message string

#### `update-reporter-status`

Enable or disable a reporter.

```
(update-reporter-status "reporter1" false)
```

**Parameters:**
- `reporter`: Reporter identifier
- `is-active`: Boolean status

**Returns:** Success message string

#### `update-symbol-status`

Enable or disable a trading pair.

```
(update-symbol-status "KDA/USD" false)
```

**Parameters:**
- `symbol`: Symbol identifier
- `is-active`: Boolean status

**Returns:** Success message string

### Reporter Functions

#### `submit-report`

Submit a new price report for a symbol.

```
(submit-report "KDA/USD" "reporter1" 0.62)
```

**Parameters:**
- `symbol`: Symbol to report for
- `reporter`: Reporter identifier
- `value`: Price value as decimal

**Returns:** Success message string

**Flow:**
1. Validates symbol and reporter are active
2. Checks reporting time constraints
3. Updates reporter's next report time with randomization
4. Stores the report
5. Updates the recent reports list
6. Updates the oracle value with the latest median

### Client Functions

#### `get-price`

Get the current price for a symbol.

```
(get-price "KDA/USD")
```

**Parameters:**
- `symbol`: Symbol to query

**Returns:** Object with:
- `timestamp`: Time of the oldest report in the aggregation set
- `value`: Median value of the aggregated reports

Example return value:
```
{"timestamp": "2023-06-15T10:30:00Z", "value": 0.62}
```

### Helper Functions

#### `check-reporter-time`

Check when a reporter is allowed to submit next.

```
(check-reporter-time "reporter1")
```

**Parameters:**
- `reporter`: Reporter identifier

**Returns:** String with next report time information

## Parameter Guidelines

### Symbol Configuration

For standard pairs (e.g., KDA/USD):
- `avg-interval`: 3600.0 (1 hour)
- `max-deviation`: 900.0 (15 minutes)
- `aggregation-count`: 5 reports

For critical pairs:
- `avg-interval`: 1800.0 (30 minutes)
- `max-deviation`: 300.0 (5 minutes)
- `aggregation-count`: 7-9 reports

For less critical pairs:
- `avg-interval`: 7200.0 (2 hours)
- `max-deviation`: 1800.0 (30 minutes)
- `aggregation-count`: 3 reports

## Security Considerations

1. **Reporter Authentication**: All reporters are authenticated using their guardset
2. **Time Constraints**: Reporters can only submit at their assigned time windows
3. **Governance Control**: Symbol and reporter management requires OPS capability
4. **Internal Capabilities**: Report updating is protected by internal capabilities

## Example Usage

### Setting up the Oracle

```
;; Add reporters
(add-reporter "exchange-a" "Exchange A Reporter" (read-keyset 'exchange-a-ks))
(add-reporter "exchange-b" "Exchange B Reporter" (read-keyset 'exchange-b-ks))
(add-reporter "exchange-c" "Exchange C Reporter" (read-keyset 'exchange-c-ks))

;; Add symbols
(add-symbol "KDA/USD" 3600.0 900.0 5)
(add-symbol "KDA/BTC" 3600.0 900.0 5)
```

### Submitting Reports

```
;; Submit price reports
(submit-report "KDA/USD" "exchange-a" 0.61)
(submit-report "KDA/USD" "exchange-b" 0.62)
(submit-report "KDA/USD" "exchange-c" 0.6)
```

### Reading Prices

```
;; Get current price
(get-price "KDA/USD")
;; Returns: {"timestamp": "2023-06-15T10:30:00Z", "value": 0.61}
```

## Design Rationale

1. **Using Multiple Reporters**: Improves reliability and reduces dependency on any single data source

2. **Median Aggregation**: Eliminates outliers and reduces impact of potentially corrupted reporters

3. **Timestamp Validation**: Provides a way for clients to assess data freshness

4. **Time-Spread Reporting**: Ensures reports are naturally distributed and reduces network congestion

5. **Report History**: Maintains only the necessary reports for aggregation to optimize storage

This oracle design prioritizes reliability and simplicity, making it suitable for DeFi applications that require trustworthy price data without the complexity of fully decentralized oracle networks.
