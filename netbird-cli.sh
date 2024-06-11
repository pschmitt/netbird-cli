#!/usr/bin/env bash

NB_API_TOKEN="${NB_API_TOKEN:-}"
NB_API_URL="${NB_API_URL:-https://nb.gec.io}"
RESOLVE="${RESOLVE:-}"
OUTPUT="${OUTPUT:-pretty}"
JQ_ARGS=()

usage() {
  echo "Usage: $(basename "$0") [options] ITEM [ACTION] [ARGS...]"
  echo
  echo "Options:"
  echo "  -h, --help           Show this help message and exit"
  echo "  -u, --url <url>      Set the NetBird API URL"
  echo "  -t, --token <token>  Set the NetBird API token"
  echo "  -J, --jq-args <args> Add arguments to jq"
  echo "  -o, --output <mode>  Set the output mode (json, pretty)"
  echo "  -j, --json           Output raw JSON (shorthand for -o json)"
  echo "  -N, --no-header      Do not show the header row"
  echo "  -c, --no-color       Do not colorize the output"
  echo "  -r, --resolve        Resolve group names for setup keys"
  echo
  echo "Items and Actions:"
  echo "  accounts    list            List accounts"
  echo
  echo "  country     list [COUNTRY]  List countries or get cities for a specific country"
  echo
  echo "  dns         list [ID/NAME]  List nameservers groups or get a specific ns by ID or name"
  echo
  echo "  events      list            List events"
  echo
  echo "  groups      list [ID/NAME]          List groups or get a specific group by ID or name"
  echo "              create NAME [PEER1...]  Create a group with optional peers"
  echo "              delete ID/NAME          Delete a group by ID or name"
  echo
  echo "  peers       list [ID/NAME]          List peers or get a specific peer by ID or name"
  echo
  echo "  posture     list [ID/NAME]          List posture checks or get a specific check by ID or name"
  echo
  echo "  routes      list [ID/NAME]          List routes or get a specific route by ID or name"
  echo
  echo "  setup-keys  list [ID/NAME]          List setup keys or get a specific key by ID or name"
  echo "              create NAME [OPTIONS]   Create a setup key with the given name and options"
  echo "              revoke ID/NAME          Revoke a setup key by ID or name"
  echo
  echo "  tokens      list USER                   List tokens for a specific user"
  echo "              create USER NAME [OPTIONS]  Create a token for a user with the given name and options"
  echo "              delete USER TOKEN           Delete a token for a user by token name or ID"
  echo
  echo "  users       list [ID/NAME]  List users or get a specific user by ID or name"
  echo "  whoami      Get the current user"
}

usage_create_setup_key() {
  echo "Usage: $(basename "$0") setup-keys create NAME [OPTIONS]"
  echo
  echo "Options:"
  echo "  -h, --help            Show this help message and exit"
  echo "  -g, --auto-groups     Add the setup key to the specified groups"
}

arr_to_json() {
  printf '%s\n' "$@" | jq -Rn '[inputs]'
}

# shellcheck disable=SC2120
colorizecolumns() {
  if [[ -n "$NO_COLOR" ]]
  then
    cat "$@"
    return "$?"
  fi

  awk '
    BEGIN {
      # Define colors
      colors[0] = "\033[36m" # cyan
      colors[1] = "\033[32m" # green
      colors[2] = "\033[35m" # magenta
      colors[3] = "\033[37m" # white
      colors[4] = "\033[33m" # yellow
      colors[5] = "\033[34m" # blue
      colors[6] = "\033[38m" # gray
      colors[7] = "\033[31m" # red
      reset = "\033[0m"
    }

    {
      field_count = 0

      # Process the line character by character
      for (i = 1; i <= length($0); i++) {
        # Current char
        char = substr($0, i, 1)

        if (char ~ /[\t]/) {
          # If the character is a space or tab, just print it
          printf "%s", char
        } else {
          # Apply color to printable characters
          color = colors[field_count % length(colors)]
          printf "%s%s%s", color, char, reset
          # Move to the next field after a space or tab
          if (substr($0, i + 1, 1) ~ /[\t]/) {
            field_count++
          }
        }
      }

      # Append trailing NL
      printf "\n"
    }' "$@"
}

nb_curl() {
  local endpoint="$1"
  shift
  local url="${NB_API_URL}/api/${endpoint}"

  curl -fsSL \
    -H "Authorization: Token $NB_API_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$@" \
    "$url"
}

# Check whether a provided string is a NetBird ID
is_nb_id() {
  local thing="$1"

  if [[ "$thing" =~ ^[0-9a-z]{20}$ && "$thing" =~ .*[0-9]+.* ]]
  then
    return 0
  fi

  # User IDs are uuids
  local uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  if [[ $thing =~ $uuid_re ]]
  then
    return 0
  fi

  return 1
}

# https://docs.netbird.io/api/resources/accounts#list-all-accounts
nb_list_accounts() {
  nb_curl accounts
}

# https://docs.netbird.io/api/resources/events#list-all-events
nb_list_events() {
  nb_curl events
}

# https://docs.netbird.io/api/resources/groups#list-all-groups
nb_list_groups() {
  local endpoint="groups"

  if [[ -n "$1" ]]
  then
    endpoint="groups/${1}"
  fi

  nb_curl "$endpoint"
}

# Get the group ID, given the group name
nb_group_id() {
  local group_name="$1"

  nb_list_groups "$1" | jq -er --arg group_name "$group_name" '
    .[] | select(.name == $group_name) | .id
  '
}

# https://docs.netbird.io/api/resources/groups#create-a-group
# Usage: nb_create_group NAME [PEER1 PEER2 ...]
nb_create_group() {
  local name="$1"
  shift

  local peers=("$@")
  local peers_json="null"
  if [[ ${#peers[@]} -gt 0 ]]
  then
    peers_json=$(arr_to_json "${peers[@]}")
  fi

  local data
  data=$(jq -Rcsn --arg name "$name" --argjson peers "$peers_json" \
    '{name: $name, peers: $peers}')

  nb_curl groups -X POST --data-raw "$data"
}

# https://docs.netbird.io/api/resources/groups#delete-a-group
nb_delete_group() {
  local group="$1"

  if [[ -z "$group" ]]
  then
    echo "Missing group ID/name" >&2
    return 2
  fi

  if ! is_nb_id "$group"
  then
    group_id=$(nb_group_id "$group")

    if [[ -z "$group_id" ]]
    then
      echo "Failed to determine group ID of '$group'" >&2
      return 1
    fi

    group="$group_id"
  fi

  nb_curl "groups/${group}" -X DELETE
}

# https://docs.netbird.io/api/resources/geo-locations#list-all-country-codes
nb_list_countries() {
  local endpoint="locations/countries"

  if [[ -n "$1" ]]
  then
    endpoint+="/${1}/cities"
  fi

  nb_curl "$endpoint"
}

# https://docs.netbird.io/api/resources/dns#list-all-nameserver-groups
nb_list_dns() {
  local endpoint="dns/nameservers"

  if [[ -n "$1" ]]
  then
    endpoint+="/${1}"
  fi

  nb_curl "$endpoint"
}

# https://docs.netbird.io/api/resources/peers#list-all-peers
nb_list_peers() {
  local endpoint="peers"

  if [[ -n "$1" ]]
  then
    if is_nb_id "$1"
    then
      endpoint+="/${1}"
    else
      local peer_id
      peer_id=$(nb_peer_id "$1")

      if [[ -z "$peer_id" ]]
      then
        echo "Failed to determine peer ID of '$1'" >&2
        return 1
      fi

      if [[ $(wc -l <<< "$peer_id") -eq 1 ]]
      then
        endpoint+="/${peer_id}"
      else
        echo "Multiple peers found with the name '$1'" >&2

        for peer in $peer_id
        do
          nb_list_peers "$peer"
        done | jq -es

        return "$?"
      fi
    fi
  fi

  nb_curl "$endpoint"
}

nb_peer_id() {
  local peer_name="$1"
  nb_list_peers | jq -er --arg peer_name "$peer_name" '
    .[] | select(.hostname == $peer_name) | .id
  '
}

# https://docs.netbird.io/api/resources/posture-checks#list-all-posture-checks
# shellcheck disable=SC2120
nb_list_posture_checks() {
  local endpoint="posture-checks"

  if [[ -n "$1" ]]
  then
    if is_nb_id "$1"
    then
      endpoint+="/${1}"
    else
      local posture_check_id
      posture_check_id=$(nb_posture_check_id "$1")

      if [[ -z "$posture_check_id" ]]
      then
        echo "Failed to determine posture check ID of '$1'" >&2
        return 1
      fi

      endpoint+="/${posture_check_id}"
    fi
  fi

  nb_curl "$endpoint"
}

nb_posture_check_id() {
  local posture_check_name="$1"
  nb_list_posture_checks | jq -er --arg posture_check_name "$posture_check_name" '
    .[] | select(.name == $posture_check_name) | .id
  '
}

# https://docs.netbird.io/api/resources/routes#list-all-routes
# shellcheck disable=SC2120
nb_list_routes() {
  local endpoint="routes"

  if [[ -n "$1" ]]
  then
    if is_nb_id "$1"
    then
      endpoint+="/${1}"
    else
      local route_id
      route_id=$(nb_route_id "$1")

      if [[ -z "$route_id" ]]
      then
        echo "Failed to determine route ID of '$1'" >&2
        return 1
      fi

      endpoint+="/${route_id}"
    fi
  fi

  local data
  if ! data=$(nb_curl "$endpoint")
  then
    echo "Failed to list routes" >&2
    return 1
  fi

  if [[ -z "$RESOLVE" ]]
  then
    printf '%s\n' "$data"
    return 0
  fi

  local groups
  groups=$(nb_list_groups)
  if [[ -z "$groups" ]]
  then
    echo "Failed to list groups" >&2
    return 1
  fi

  <<<"$data" jq -er --argjson groups "$groups" '
    map(
      . + {
        groups: (
          .groups // [] | map((
            . as $id | $groups[] | select(.id == $id) |
            { name: .name, id: $id }
            // { name: "**Unknown Group**", id: $id }
          ))
        ),
        peer_groups: (
          .peer_groups // [] | map((
            . as $id | $groups[] | select(.id == $id) |
            { name: .name, id: $id }
            // { name: "**Unknown Group**", id: $id }
          ))
        )
      }
    )
  '
}

nb_route_id() {
  local route_name="$1"
  nb_list_routes | jq -er --arg route_name "$route_name" '
    .[] | select(.name == $route_name) | .id
  '
}

# https://docs.netbird.io/api/resources/setup-keys#list-all-setup-keys
nb_list_setup_keys() {
  local endpoint="setup-keys"
  if [[ -n "$1" ]]
  then
    if is_nb_id "$1"
    then
      endpoint+="/${1}"
    else
      local setup_key_id
      setup_key_id=$(nb_setup_key_id "$1")

      if [[ -z "$setup_key_id" ]]
      then
        echo "Failed to determine setup key ID of '$1'" >&2
        return 1
      fi

      endpoint+="/${setup_key_id}"
    fi
  fi

  local data
  if ! data=$(nb_curl "$endpoint")
  then
    echo "Failed to list setup keys" >&2
    return 1
  fi

  if [[ -z "$RESOLVE" ]]
  then
    printf '%s\n' "$data"
    return 0
  fi

  local groups
  groups=$(nb_list_groups)
  if [[ -z "$groups" ]]
  then
    echo "Failed to list groups" >&2
    return 1
  fi

  <<<"$data" jq -er --argjson groups "$groups" '
    map(
      . + {
        auto_groups: (
          .auto_groups // [] | map((
            . as $id | $groups[] | select(.id == $id) |
            { name: .name, id: $id }
            // { name: "**Unknown Group**", id: $id }
          ))
        )
      }
    )
  '
}

# https://docs.netbird.io/api/resources/setup-keys#list-all-setup-keys
nb_setup_key_id() {
  local setup_key_name="$1"

  nb_list_setup_keys | jq -er --arg setup_key_name "$setup_key_name" '
    .[] | select(.name == $setup_key_name) | .id
  '
}

# https://docs.netbird.io/api/resources/setup-keys#create-a-setup-key
nb_create_setup_key() {
  local args
  local -a auto_groups
  local ephemeral="${ephemeral:-true}"
  local expires_in="${expires_in:-31536000}" # 1 year
  local revoked="${revoked:-false}"
  local type="${type:-reusable}" # or: one-off
  local usage_limit=0 # unlimited

  while [[ -n "$*" ]]
  do
    case "$1" in
      -h|--help|-\?)
        usage_create_setup_key
        return 0
        ;;
      -e|--ephemeral)
        case "$2" in
          true|t|1)
            ephemeral=true
            ;;
          *)
            ephemeral=false
            ;;
        esac
        shift 2
        ;;
      -E|--expir*)
        expires_in="$2"
        shift 2
        ;;
      -g|--auto-groups|--group*)
        auto_groups+=("$2")
        shift 2
        ;;
      -l|--usage-limit)
        usage_limit="$2"
        shift 2
        ;;
      -r|--revoked)
        case "$2" in
          true|t|1)
            revoked=true
            ;;
          *)
            revoked=false
            ;;
        esac
        shift 2
        ;;
      -t|--type)
        type="$2"
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  set -- "${args[@]}"

  local name="$1"
  shift

  local auto_groups_json=null
  if [[ "${#auto_groups[@]}" -gt 0 ]]
  then
    auto_groups_json=$(arr_to_json "${auto_groups[@]}")
  fi

  local data
  data=$(jq -Rcsn \
    --arg name "$name" \
    --arg type "$type" \
    --argjson expires_in "$expires_in" \
    --argjson revoked "$revoked" \
    --argjson auto_groups "$auto_groups_json" \
    --argjson usage_limit "$usage_limit" \
    --argjson ephemeral "$ephemeral" '
      {
        name: $name,
        type: $type,
        expires_in: $expires_in,
        revoked: $revoked,
        auto_groups: $auto_groups,
        usage_limit: $usage_limit,
        ephemeral: $ephemeral
      }
    ')

  nb_curl setup-keys -X POST --data-raw "$data"
}

# https://docs.netbird.io/api/resources/setup-keys#update-a-setup-key
nb_revoke_setup_key() {
  local setup_key="$1"

  if [[ -z "$setup_key" ]]
  then
    echo "Missing setup_key ID/name" >&2
    return 2
  fi

  if ! is_nb_id "$setup_key"
  then
    setup_key_id=$(nb_setup_key_id "$setup_key")

    if [[ -z "$setup_key_id" ]]
    then
      echo "Failed to determine setup key ID of '$setup_key'" >&2
      return 1
    fi

    setup_key="$setup_key_id"
  fi

  local data
  data=$(nb_list_setup_keys "$setup_key" | jq -er '.revoked = true')

  nb_curl "setup-keys/${setup_key}" -X PUT --data-raw "$data"
}

# https://docs.netbird.io/api/resources/tokens#list-all-tokens
nb_list_tokens() {
  local user="$1"

  if [[ -z "$user" ]]
  then
    user=$(nb_user_id self)
  elif ! is_nb_id "$user"
  then
    local user_id
    user_id=$(nb_user_id "$user")

    if [[ -z "$user_id" ]]
    then
      echo "Failed to determine user ID of '$user'" >&2
      return 1
    fi

    user="$user_id"
  fi

  local endpoint="users/${user}/tokens"

  if [[ -n "$2" ]]
  then
    if is_nb_id "$2"
    then
      endpoint+="/${2}"
    else
      local token_id
      token_id=$(nb_token_id "$user" "$2")

      if [[ -z "$token_id" ]]
      then
        echo "Failed to determine token ID of '$2'" >&2
        return 1
      fi

      endpoint+="/${token_id}"
    fi
  fi

  nb_curl "$endpoint"
}

nb_token_id() {
  local user="$1"

  if [[ -z "$user" ]]
  then
    user=$(nb_user_id self)
  elif ! is_nb_id "$user"
  then
    local user_id
    user_id=$(nb_user_id "$user")

    if [[ -z "$user_id" ]]
    then
      echo "Failed to determine user ID of '$user'" >&2
      return 1
    fi

    user="$user_id"
  fi

  local token_name="$2"
  nb_list_tokens "$user" | jq -er --arg token_name "$token_name" '
    .[] | select(.name == $token_name) | .id
  '
}

# https://docs.netbird.io/api/resources/tokens#create-a-token
nb_create_token() {
  local user="$1"

  if [[ -z "$user" ]]
  then
    user=$(nb_user_id self)
  elif ! is_nb_id "$user"
  then
    local user_id
    user_id=$(nb_user_id "$user")
    if [[ -z "$user_id" ]]
    then
      echo "Failed to determine user ID of '$user'" >&2
      return 1
    fi

    user="$user_id"
  fi

  local name="$2"
  local expires_in="${expires_in:-365}" # 1 year

  local data
  data=$(jq -Rcsn \
    --arg name "$name" \
    --argjson expires_in "$expires_in" '
      {name: $name, expires_in: $expires_in}
    ')

  nb_curl "users/${user}/tokens" -X POST --data-raw "$data"

}

# https://docs.netbird.io/api/resources/tokens#delete-a-token
nb_delete_token() {
  local user="$1"
  local token="$2"

  if [[ -z "$user" ]]
  then
    user=$(nb_user_id self)
  elif ! is_nb_id "$user"
  then
    local user_id
    user_id=$(nb_user_id "$user")
    if [[ -z "$user_id" ]]
    then
      echo "Failed to determine user ID of '$user'" >&2
      return 1
    fi

    user="$user_id"
  fi

  if ! is_nb_id "$token"
  then
    local token_id
    token_id=$(nb_token_id "$user" "$token")
    if [[ -z "$token_id" ]]
    then
      echo "Failed to determine token ID of '$token'" >&2
      return 1
    fi

    token="$token_id"
  fi

  nb_curl "users/${user}/tokens/${token}" -X DELETE
}

# https://docs.netbird.io/api/resources/users#list-all-users
# shellcheck disable=SC2120
nb_list_users() {
  local endpoint="users"

  if [[ -n "$1" ]]
  then
    if is_nb_id "$1"
    then
      endpoint+="/${1}"
    else
      local user_id
      user_id=$(nb_user_id "$1")

      if [[ -z "$user_id" ]]
      then
        echo "Failed to determine user ID of '$1'" >&2
        return 1
      fi

      endpoint+="/${user_id}"
    fi
  fi

  local data
  if ! data=$(nb_curl "$endpoint")
  then
    echo "Failed to list users" >&2
    return 1
  fi

  if [[ -z "$RESOLVE" ]]
  then
    printf '%s\n' "$data"
    return 0
  fi

  local groups
  groups=$(nb_list_groups)
  if [[ -z "$groups" ]]
  then
    echo "Failed to list groups" >&2
    return 1
  fi

  <<<"$data" jq -er --argjson groups "$groups" '
    map(
      . + {
        auto_groups: (
          .auto_groups // [] | map((
            . as $id | $groups[] | select(.id == $id) |
            { name: .name, id: $id }
            // { name: "**Unknown Group**", id: $id }
          ))
        )
      }
    )
  '
}

nb_whoami() {
  nb_list_users | \
    jq -er '.[] | select(.is_current)'
}

nb_user_id() {
  local user_name="$1"

  if [[ "$user_name" == "self" ]]
  then
    nb_whoami | jq -er '.id'
    return "$?"
  fi

  nb_list_users | jq -er --arg user_name "$user_name" '
  .[] | select(.name == $user_name or .email == $user_name) | .id
  '
}

main() {
  local ARGS=()

  while [[ -n "$*" ]]
  do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -u|--url)
        NB_API_URL="$2"
        shift 2
        ;;
      -t|--token)
        NB_API_TOKEN="$2"
        shift 2
        ;;
      -J|--jq-args)
        JQ_ARGS+=("$2")
        shift 2
        ;;
      -o|--output)
        OUTPUT="$2"
        shift 2
        ;;
      -j|--json)
        OUTPUT=json
        shift
        ;;
      -i|--id*)
        WITH_ID_COL=1
        shift
        ;;
      -N|-no-header)
        NO_HEADER=1
        shift
        ;;
      -c|--no-color)
        NO_COLOR=1
        shift
        ;;
      -r|--resolve)
        RESOLVE=1
        shift
        ;;
      *)
        ARGS+=("$1")
        shift
        ;;
    esac
  done

  set -- "${ARGS[@]}"

  if [[ -z "$1" ]]
  then
    echo "Missing item" >&2
    usage >&2
    exit 2
  fi

  if [[ -z "$NB_API_TOKEN" ]]
  then
    echo "Missing API token" >&2
    echo "Either set NB_API_TOKEN or use the -t option" >&2
    exit 2
  fi

  API_ITEM="$1"
  shift

  ACTION=list
  if [[ -n "$1" ]]
  then
    ACTION="$1"
    shift
  fi

  COLUMNS=(name)
  COLUMN_NAMES=(Name)

  case "$API_ITEM" in
    a|acc*)
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_accounts
          ;;
      esac
      ;;
    country*|geo*)
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_countries
          ;;
      esac
      ;;
    d|dns*|ns*|nameser*)
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_dns
          ;;
      esac
      ;;
    e|event*)
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_events
          ;;
      esac
      ;;
    g|gr*)
      COLUMNS=(name peers)
      COLUMN_NAMES=("Name" Peers)
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_groups
          ;;
        create)
          COMMAND=nb_create_group
          ;;
        delete)
          COMMAND=nb_delete_group
          ;;
      esac
      ;;
    p|peer*)
      COLUMNS=(hostname ip dns_label connected version)
      COLUMN_NAMES=(Hostname "Netbird IP" "DNS" Connected Version)
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_peers
          ;;
      esac
      ;;
    postu*)
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_posture_checks
          ;;
      esac
      ;;
    r|ro*)
      COLUMNS=(network_id network masquerade metric groups peer_groups)
      COLUMN_NAMES=("Net ID" "Network" "MASQ" "Metric" "Dist Groups" "Peer Groups")
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_routes
          ;;
      esac
      ;;
    s|setup*)
      COLUMNS=(name auto_groups state)
      COLUMN_NAMES=("Name" Groups State)
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_setup_keys
          ;;
        create)
          COMMAND=nb_create_setup_key
          ;;
        delete|revoke)
          COMMAND=nb_revoke_setup_key
          ;;
      esac
      ;;
    t|token*)
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_tokens
          ;;
        create)
          COMMAND=nb_create_token
          ;;
        delete)
          COMMAND=nb_delete_token
          ;;
      esac
      ;;
    u|user*)
      COLUMNS=(name role auto_groups)
      COLUMN_NAMES=(Name Role "Groups")
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_users
          ;;
      esac
      ;;
    w|whoami|self|me)
      COLUMNS=(name role auto_groups)
      COLUMN_NAMES=(Name Role "Groups")
      case "$ACTION" in
        list|get)
          COMMAND=nb_whoami
          ;;
      esac
      ;;
  esac

  if [[ "$OUTPUT" == "pretty" ]]
  then
    RESOLVE=1
  fi

  if [[ -n "$WITH_ID_COL" ]]
  then
    COLUMNS=(id "${COLUMNS[@]}")
    COLUMN_NAMES=(ID "${COLUMN_NAMES[@]}")
  fi

  "$COMMAND" "$@" | {
    case "$OUTPUT" in
      json)
        jq -e "${JQ_ARGS[@]}"
        ;;
      pretty)
        {
          if [[ -z "$NO_HEADER" ]]
          then
            # shellcheck disable=SC2031
            for col in "${COLUMN_NAMES[@]}"
            do
              echo -ne "\e[1m${col}\e[0m\t"
            done
            echo
          fi
          # shellcheck disable=SC2031
          COLUMNS_JSON=$(arr_to_json "${COLUMNS[@]}")

          jq -er --argjson cols_json "$COLUMNS_JSON" '
            def extractFields:
              . as $obj |
              reduce $cols_json[] as $field (
                {}; . + {
                  ($field | gsub("\\."; "_")): $obj | getpath($field / ".")
                }
              );

            . |
            if (. | type == "array")
            then
              sort_by((.["name"]? // .["description"]) | ascii_downcase) |
              map(extractFields)[]
            else
              extractFields
            end |
            map(
              if (. | type == "array")
              then
                ([.[].name] | sort | join(","))
              else
                .
              end
            ) | @tsv
          ' | \
          colorizecolumns
        } | column -t -s '	'
        ;;
    esac
  }
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  main "$@"
fi
