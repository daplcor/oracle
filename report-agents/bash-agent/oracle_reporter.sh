#!/bin/bash
VERSION="1.0"
CONFIG_FILE=${1:-"reporter.json"}
KDA=`which kda`

echo "Oracle Reporter v$VERSION"

if [ -z $CONFIG_FILE ]
then
  echo "Missing config"
  exit 1
fi

# Check that all files are present
for _file in $CONFIG_FILE "gas.key" "reporter.key"
do
  if ! [ -f $_file ]
  then
    echo "File not found:" $_file
    exit 1
  fi
done

if [ -z $KDA ]
then
  echo "kda tool missing"
  exit 1
fi

mkdir -p archives

function get_value () {
  SOURCE=`jq -r ".source" < $CONFIG_FILE`
  KEY=`jq -r '."source-api-key"' < $CONFIG_FILE`

  case $SOURCE in

    TRADEOGRE|tradeogre|Tradeogre)
      echo "Retrieving TradeOgre ticker"
      VALUE=`curl -s https://tradeogre.com/api/v1/markets | jq -r '.[] | select(."KDA-USDT") | .[].price'`;;
    BINANCE|binance|Binance)
      echo "Retrieving Binance ticker"
      VALUE=`curl -s https://data-api.binance.vision/api/v3/avgPrice?symbol=KDAUSDT |jq -r ".price"`;;
    COINEX|coinex|Coinex|CoinEx)
      echo "Retrieving CoinEx ticker"
      VALUE=`curl -s https://api.coinex.com/v2/spot/ticker?market=KDAUSDT|jq -r ".data[0].last"`;;
    KUCOIN|Kucoin|kucoin)
      echo "Retrieving Kucoin ticker"
      VALUE=`curl -s https://api.kucoin.com/api/v1/market/orderbook/level1?symbol=KDA-USDT| jq -r ".data.price"`;;
    COINGECKO|coingecko|CoinGecko)
      echo "Retrieving CoinGecko price"
      VALUE=`curl -s -H "x-cg-demo-api-key: $KEY" "https://api.coingecko.com/api/v3/simple/price?ids=kadena&vs_currencies=usd" |jq -r ".kadena.usd"`;;
    CMC|Coinmarketcap|COINMARKETCAP|coinmarketcap)
      echo "Retrieving CoinMarketCap ticker"
      VALUE=`curl -s -H "X-CMC_PRO_API_KEY: $KEY" https://pro-api.coinmarketcap.com/v2/cryptocurrency/quotes/latest?symbol=KDA |jq ".data.KDA |.[0].quote.USD.price"`;;
    *)
      echo "Unknown source"
      exit -1
  esac
  echo "KDA/USD value": $VALUE
  if [ -z $VALUE ] || [ $VALUE = "null" ]
  then
    echo "Retrieved value Invalid"
    return 1
  fi
}


function get_chain_time () {
TKPL=`mktemp`
YAML=`mktemp`
cat << EOF >> $TKPL
code: (free.util-time.now)
publicMeta:
  chainId: "{{chain}}"
  sender: ""
  gasLimit: 2000
  gasPrice: 0.00000001
  ttl: 600
networkId: "{{network}}"
type: exec
EOF

$KDA gen -t $TKPL -o $YAML -d $CONFIG_FILE > /dev/null
_chain_time=`$KDA local  $YAML --no-verify-sigs |jq -r ".[][0].body.result.data | if .timep then .timep else .time end"`

if [ $_chain_time = "null" ]
then
  echo "Unable to retieve the chain time"
  $KDA local  $YAML --no-verify-sigs |jq
  rm $TKPL $YAML
  return 1
fi

echo "Chain time: " $_chain_time
CHAIN_TIME=`date +%s --date=${_chain_time}`
rm $TKPL $YAML
}

function get_reporter_time () {
TKPL=`mktemp`
YAML=`mktemp`
cat << EOF >> $TKPL
code: ({{oracle}}.check-reporter-time "{{reporter}}" "{{symbol}}")
publicMeta:
  chainId: "{{chain}}"
  sender: ""
  gasLimit: 2000
  gasPrice: 0.00000001
  ttl: 600
networkId: "{{network}}"
type: exec
EOF

$KDA gen -t $TKPL -o $YAML -d $CONFIG_FILE > /dev/null
_reporter_time=`$KDA local  $YAML --no-verify-sigs |jq -r ".[][0].body.result.data | if .timep then .timep else .time end"`

if [ $_reporter_time = "null" ]
then
  echo "Unable to retieve the reporter time"
  $KDA local  $YAML --no-verify-sigs |jq
  rm $TKPL $YAML
  return 1
fi

echo "Next report:" $_reporter_time
REPORTER_TIME=`date +%s --date=${_reporter_time}`
rm $TKPL $YAML
}

function submit_report () {
TKPL=`mktemp`
YAML=`mktemp --suffix=.yaml`
JSON=${YAML%.yaml}.json

cat << EOF >> $TKPL
code: ({{oracle}}.submit-report "{{symbol}}" "{{reporter}}" (read-decimal 'value))
data:
  value: "$1"
publicMeta:
  chainId: "{{chain}}"
  sender: "{{gas-payer}}"
  gasLimit: 600
  gasPrice: 0.00000001
  ttl: 600
networkId: "{{network}}"
signers:
  - public: {{gas-key}}
    caps:
      - name: "coin.GAS"
        args: []
  - public: {{reporter-key}}
    caps:
      - name: {{oracle}}.REPORTER
        args:
          - {{reporter}}
          - {{symbol}}
type: exec
EOF
$KDA gen -t $TKPL -o $YAML -d $CONFIG_FILE > /dev/null
$KDA sign $YAML -k gas.key > /dev/null
$KDA sign $YAML -k reporter.key > /dev/null

if [ -e $JSON ]
then
  echo "Transaction:" `jq -r ".hash" < $JSON`
else
  echo "Transaction building error"
  rm $TKPL $YAML
  return 1
fi

LOCAL_STATUS=`$KDA local $JSON | jq -r ".[][0].body.result.status"`

if [ $LOCAL_STATUS = "success" ]
then
  echo "Sending transaction"
  $KDA send $JSON
  cp $JSON archives/`jq -r ".hash" < $JSON`.json
else
  echo "Error in local call"
  $KDA local $JSON | jq
  rm $TKPL $YAML $JSON
  return 1
fi

rm $TKPL $YAML $JSON
}


get_value

while true
do
  get_chain_time && get_reporter_time

  if [ $? -ne 0 ]
  then
    sleep 30
    continue
  fi

  delta=$(($REPORTER_TIME - $CHAIN_TIME))
  echo "Next report expected in" $delta "seconds"
  if [ $delta -ge 0 ]
  then
    sleep $(($delta +5 ))
  else
    get_value && submit_report $VALUE
    sleep 300
  fi

done