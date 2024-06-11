#!/usr/bin/env bash

NB_API_TOKEN="${NB_API_TOKEN:-}"
NB_API_URL="${NB_API_URL:-https://nb.gec.io}"
RESOLVE="${RESOLVE:-}"
JQ_ARGS=()

usage() {
  echo "Usage: $(basename "$0") [options] ITEM [ACTION] [ARGS...]"
  echo
  echo "Options:"
  echo "  -h, --help           Show this help message and exit"
  echo "  -u, --url <url>      Set the NetBird API URL"
  echo "  -t, --token <token>  Set the NetBird API token"
  echo "  -j, --jq-args <args> Add arguments to jq"
  echo "  -r, --resolve        Resolve group names for setup keys"
  echo
  echo "Items and Actions:"
  echo "  accounts    list     List accounts"
  echo
  echo "  events      list     List events"
  echo
  echo "  geo         list [COUNTRY]          List countries or get cities for a specific country"
  echo
  echo "  groups      list [ID/NAME]          List groups or get a specific group by ID or name"
  echo "              create NAME [PEER1...]  Create a group with optional peers"
  echo "              delete ID/NAME          Delete a group by ID or name"
  echo
  echo "  peers       list [ID/NAME]          List peers or get a specific peer by ID or name"
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

is_nb_id() {
  local thing="$1"

  # User IDs are uuids
  local uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

  if ! [[ "$thing" =~ ^[0-9a-f]{20}$ ]]
  then
    if [[ $thing =~ $uuid_re ]]
    then
      return 0
    fi
    return 1
  fi

  return 0
}

nb_list_accounts() {
  nb_curl accounts
}

nb_list_events() {
  nb_curl events
}

# https://docs.netbird.io/api/resources/groups#list-all-groups
nb_list_groups() {
  if [[ -n "$1" ]]
  then
    nb_curl "groups/${1}"
  else
    nb_curl groups
  fi
}

# Get the group ID, given the group name
nb_group_id() {
  local group_name="$1"

  nb_list_groups | jq -er --arg group_name "$group_name" '
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

nb_list_countries() {
  local endpoint="locations/countries"

  if [[ -n "$1" ]]
  then
    endpoint="${endpoint}/${1}/cities"
  fi

  nb_curl "$endpoint"
}

nb_list_peers() {
  if [[ -n "$1" ]]
  then
    nb_curl "peers/${1}"
  else
    nb_curl peers
  fi
}

nb_list_routes() {
  if [[ -n "$1" ]]
  then
    nb_curl "routes/${1}"
  else
    nb_curl routes
  fi
}

# https://docs.netbird.io/api/resources/setup-keys#list-all-setup-keys
nb_list_setup_keys() {
  local data
  if ! data=$({
    if [[ -n "$1" ]]
    then
      nb_curl "setup-keys/${1}"
    else
      nb_curl setup-keys
    fi
  })
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

  if ! is_nb_id "$user"
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

  nb_curl "users/${user}/tokens"
}

nb_token_id() {
  local user="$1"

  if ! is_nb_id "$user"
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

  if ! is_nb_id "$user"
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

  if ! is_nb_id "$user"
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
nb_list_users() {
  if [[ -n "$1" ]]
  then
    nb_curl "users/${1}"
  else
    nb_curl users
  fi
}

nb_user_id() {
  local user_name="$1"
  nb_list_users | jq -er --arg user_name "$user_name" '
    .[] | select(.name == $user_name or .email == $user_name) | .id
  '
}

main() {
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
      -j|--jq-args)
        JQ_ARGS+=("$2")
        shift 2
        ;;
      -r|--resolve)
        RESOLVE=1
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ -z "$1" ]]
  then
    echo "Missing item" >&2
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

  {
    case "$API_ITEM" in
      a|acc*)
        case "$ACTION" in
          list|get)
            nb_list_accounts "$@"
            ;;
        esac
        ;;
      e|event*)
        case "$ACTION" in
          list|get)
            nb_list_events "$@"
            ;;
        esac
        ;;
      g|gr*)
        case "$ACTION" in
          list|get)
            nb_list_groups "$@"
            ;;
          create)
            nb_create_group "$@"
            ;;
          delete)
            nb_delete_group "$@"
            ;;
        esac
        ;;
      geo*)
        case "$ACTION" in
          list|get)
            nb_list_countries "$@"
            ;;
        esac
        ;;
      p|peer*)
        case "$ACTION" in
          list|get)
            nb_list_peers "$@"
            ;;
        esac
        ;;
      r|ro*)
        case "$ACTION" in
          list|get)
            nb_list_routes "$@"
            ;;
        esac
        ;;
      s|setup*)
        case "$ACTION" in
          list|get)
            nb_list_setup_keys "$@"
            ;;
          create)
            nb_create_setup_key "$@"
            ;;
          delete|revoke)
            nb_revoke_setup_key "$@"
            ;;
        esac
        ;;
      t|token*)
        case "$ACTION" in
          list|get)
            nb_list_tokens "$@"
            ;;
          create)
            nb_create_token "$@"
            ;;
          delete)
            nb_delete_token "$@"
            ;;
        esac
        ;;
      u|user*)
        case "$ACTION" in
          list|get)
            nb_list_users "$@"
            ;;
        esac
        ;;
    esac
  } | jq -e "${JQ_ARGS[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  main "$@"
fi
