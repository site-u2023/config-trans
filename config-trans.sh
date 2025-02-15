#!/bin/sh
#
# config-trans
#   - Usage:
#       config-trans <configName> [<version>]
#         e.g.) config-trans system 19.07
#               config-trans wireless
#   - 説明:
#       1) 第1引数: コンフィグ名 (例: system, wireless 等)
#          - /etc/config/<configName> を読み込み、UCI コマンド列に変換
#       2) 第2引数: バージョン (例: "19.07", "24.10" など)
#          - 省略された場合は自動検出 (AUTO_DETECT_VERSION=true のとき)
#       3) 変換結果は /tmp/config_trans/<configName>.uci に書き出される
#       4) BusyBox ash で動くように POSIX シェル構文で記述
#
#   - 対応バージョン: 19.07～24.x (自動検出 or 明示指定)
#   - 注意:
#       - 特殊構文や include 行等は未対応 (シンプルな option / list / config のみ)
#       - config <type> <name> がない場合は @type[0], @type[1] などの形式を割り当てる
#       - list は "uci add_list ..." に変換
#       - コンソール上でテスト後、必要に応じて本番適用してください
#
###############################################################################


# ▼ フラグ: true なら version 未指定時に自動検出
AUTO_DETECT_VERSION=true

# ▼ ここで対応バージョンを定義(あくまでサンプル)
SUPPORTED_VERSIONS="19 20 21 22 23 24"

# 作業ディレクトリ
OUTPUT_DIR="/tmp/config_trans"
mkdir -p "$OUTPUT_DIR"

# --- 引数解析 ---
CONFIG_NAME="$1"
MANUAL_VERSION="$2"

if [ -z "$CONFIG_NAME" ]; then
    echo "Usage: $0 <configName> [<version>]"
    echo " e.g.) $0 system 19.07"
    exit 1
fi

# --- バージョン決定ロジック ---
if [ -n "$MANUAL_VERSION" ]; then
    # 手動指定あり
    OPENWRT_VER="$MANUAL_VERSION"
    DETECTED="(manual)"
elif [ "$AUTO_DETECT_VERSION" = "true" ] && [ -f /etc/openwrt_release ]; then
    # /etc/openwrt_release から DISTRIB_RELEASE を切り出す
    OPENWRT_VER="$(awk -F"'" '/DISTRIB_RELEASE/{print $2}' /etc/openwrt_release | cut -d'-' -f1)"
    DETECTED="(auto)"
else
    # 指定なし & 自動検出しない場合
    OPENWRT_VER="unknown"
    DETECTED="(not found)"
fi

# サポートチェック(単純に major 部分だけ判定)
MAJOR_VER="$(echo "$OPENWRT_VER" | cut -d'.' -f1)"
FOUND_SUPPORT=false
for v in $SUPPORTED_VERSIONS; do
    if [ "$MAJOR_VER" = "$v" ]; then
        FOUND_SUPPORT=true
        break
    fi
done

if [ "$FOUND_SUPPORT" != "true" ]; then
    echo "Warning: OpenWrt version '$OPENWRT_VER' $DETECTED is not in supported list: [$SUPPORTED_VERSIONS]."
    echo " (continue anyway...)"
fi

# --- 変換対象ファイルを決定 ---
CONFIG_FILE="/etc/config/$CONFIG_NAME"
# もし指定フォルダにあるファイルを使いたい場合は、ここを変更可 (例: /tmp/config_trans/<configName>)

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config file not found: $CONFIG_FILE"
    exit 1
fi

# --- 出力先 ---
OUTPUT_FILE="$OUTPUT_DIR/${CONFIG_NAME}.uci"


###############################################################################
# get_index / set_index: BusyBox ash で連想配列代わりに変数を使う
###############################################################################
get_index() {
    # $1 = type名
    local type="$1"
    local var="INDEX_${type}"
    eval "val=\"\${$var:-0}\""
    echo "$val"
}

set_index() {
    # $1 = type名, $2 = 値
    local type="$1"
    local val="$2"
    local var="INDEX_${type}"
    eval "$var=\"$val\""
}

###############################################################################
# 実処理: /etc/config/<CONFIG_NAME> → uci set 形式に変換
###############################################################################
echo "# Generated by config-trans on $(date)" > "$OUTPUT_FILE"
echo "# Source: $CONFIG_FILE" >> "$OUTPUT_FILE"
echo "# OpenWrt version: $OPENWRT_VER $DETECTED" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"


CURRENT_TYPE=""
CURRENT_NAME=""
CURRENT_INDEX=""

while IFS= read -r line; do
    # trim
    line="$(echo "$line" | sed 's/^[ \t]*//; s/[ \t]*$//')"

    # 空 or #コメントは飛ばす
    [ -z "$line" ] && continue
    echo "$line" | grep -q '^#' && continue

    # "config" 行
    if echo "$line" | grep -q '^config[[:space:]]'; then
        CURRENT_TYPE=""
        CURRENT_NAME=""
        CURRENT_INDEX=""

        # 残り( e.g. "system" "system 'foo'" "wifi-iface 'ap_main'" )
        rest="$(echo "$line" | sed 's/^config[ \t]*//')"
        # quote除去
        rest="$(echo "$rest" | sed "s/^'//; s/'\$//; s/^\"//; s/\"\$//")"
        # type=最初のフィールド
        CURRENT_TYPE="$(echo "$rest" | awk '{print $1}')"
        # name= 2番目以降
        CURRENT_NAME="$(echo "$rest" | awk '{ $1=""; print $0}' | sed 's/^[ \t]*//')"

        # name が無い場合 @type[index]
        if [ -z "$CURRENT_NAME" ]; then
            idx="$(get_index "$CURRENT_TYPE")"
            CURRENT_INDEX="$idx"
            idx=$((idx+1))
            set_index "$CURRENT_TYPE" "$idx"
        fi
        continue
    fi

    # "option" 行
    if echo "$line" | grep -q '^option[[:space:]]'; then
        key="$(echo "$line" | awk '{print $2}')"
        value="$(echo "$line" \
            | sed "s/^option[ \t]*${key}[ \t]*//" \
            | sed "s/^['\"]//; s/['\"]\$//")"

        if [ -n "$CURRENT_NAME" ]; then
            echo "uci set $CONFIG_NAME.$CURRENT_NAME.$key='$value'" >> "$OUTPUT_FILE"
        else
            echo "uci set $CONFIG_NAME.@$CURRENT_TYPE[$CURRENT_INDEX].$key='$value'" >> "$OUTPUT_FILE"
        fi
        continue
    fi

    # "list" 行
    if echo "$line" | grep -q '^list[[:space:]]'; then
        key="$(echo "$line" | awk '{print $2}')"
        value="$(echo "$line" \
            | sed "s/^list[ \t]*${key}[ \t]*//" \
            | sed "s/^['\"]//; s/['\"]\$//")"
        
        if [ -n "$CURRENT_NAME" ]; then
            echo "uci add_list $CONFIG_NAME.$CURRENT_NAME.$key='$value'" >> "$OUTPUT_FILE"
        else
            echo "uci add_list $CONFIG_NAME.@$CURRENT_TYPE[$CURRENT_INDEX].$key='$value'" >> "$OUTPUT_FILE"
        fi
        continue
    fi

    # それ以外は無視
done < "$CONFIG_FILE"

echo "uci commit $CONFIG_NAME" >> "$OUTPUT_FILE"

###############################################################################
# 完了メッセージ
###############################################################################
echo "----------------------------------------"
echo "[config-trans] Convert done!"
echo "OpenWrt version: $OPENWRT_VER $DETECTED"
echo "Input:  $CONFIG_FILE"
echo "Output: $OUTPUT_FILE"
echo "----------------------------------------"
echo "サンプル: 下記コマンドで適用可能(要確認)"
echo "    eval \"\$(cat $OUTPUT_FILE)\""

exit 0
