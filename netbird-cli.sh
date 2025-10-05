#!/usr/bin/env bash

NB_API_TOKEN="${NB_API_TOKEN:-}"
NB_MANAGEMENT_URL="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
NB_CLI_CONFIG_FILE="${NB_CLI_CONFIG_FILE:-}"

COMPACT="${COMPACT:-}"
DEBUG="${DEBUG:-}"
JQ_ARGS=()
NO_COLOR="${NO_COLOR:-}"
NO_HEADER="${NO_HEADER:-}"
OUTPUT="${OUTPUT:-pretty}"
RETRIES="${RETRIES:-3}"
RESOLVE="${RESOLVE:-}"
NO_RESOLVE="${NO_RESOLVE:-}"
SORT_BY="${SORT_BY:-name}"
WITH_ID_COL="${WITH_ID_COL:-}"

# NOTE keys are singular, not plural
declare -A OBJECT_RESOLVERS=(
  [network]="network_routers,network_resources,groups"
  [route]="groups"
  [router]="groups"
)

usage() {
  echo "Usage: $(basename "$0") [options] ITEM [ACTION] [ARGS...]"
  echo
  echo "Options:"
  echo
  echo "  -h, --help           Show this help message and exit"
  echo "  --debug              Enable debug output"
  echo "  --trace              Enable trace output (implies --debug)"
  echo "  --no-warnings        Suppress warning messages"
  echo "  -u, --url <url>      Set the NetBird API URL (NB_MANAGEMENT_URL)"
  echo "  -t, --token <token>  Set the NetBird API token (NB_API_TOKEN)"
  echo "  -J, --jq-args <args> Add arguments to jq (json output only)"
  echo "  -o, --output <mode>  Set the output mode (json, pretty, plain or field)"
  echo "  -F, --field <col>    Set the (single!) output field"
  echo "  -j, --json           Output raw JSON (shorthand for -o json)"
  echo "  -N, --no-header      Do not show the header row"
  echo "  -c, --no-color       Do not colorize the output"
  echo "  --compact            Compact output (truncate)"
  echo "  --columns <cols>     Set the columns to display (comma-separated)"
  echo "  -s, --sort <col>     Sort by the specified column"
  echo "  -r, --resolve        Resolve group names for setup keys"
  echo "  --retries <int>      Number of curl retries to attempt (default: 3)"
  echo "  --config <file>      Load additional config file"
  echo
  echo "Items and Actions:"
  echo
  echo "  accounts    list                        List accounts"
  echo
  echo "  country     list [COUNTRY]              List countries or get cities for a specific country"
  echo
  echo "  dns         list [ID/NAME]              List nameservers groups or get a specific ns by ID or name"
  echo
  echo "  events      list                        List events"
  echo
  echo "  groups      list [ID/NAME]              List groups or get a specific group by ID or name"
  echo "              create NAME [PEER1...]      Create a group with optional peers"
  echo "              delete ID/NAME              Delete a group by ID or name"
  echo
  echo "  networks    list [ID/NAME]              List networks or get a specific network by ID or name"
  echo "              create ARGS                 Create a network (see --help for args)"
  echo "              delete ID/NAME              Delete a network by ID or name"
  echo
  echo "  resources   list [ID/NAME]              List network resourcess or get a specific network resource by ID or name"
  echo "              create ARGS                 Create a network resources (see --help for args)"
  echo "              delete ID/NAME              Delete a network resources by ID or name"
  echo
  echo "  peers       list [ID/NAME]              List peers or get a specific peer by ID or name"
  echo "              update NAME [OPTIONS]       Update a peer"
  echo
  echo "  policy      list [ID/NAME]              List policies or get a specific policy by ID or name"
  echo "              create ARGS                 Create a policy (see --help for args)"
  echo "              delete ID/NAME              Delete a policy by ID or name"
  echo
  echo "  posture     list [ID/NAME]              List posture checks or get a specific check by ID or name"
  echo
  echo "  routes      list [ID/NAME]              List routes or get a specific route by ID or name"
  echo "              create ARGS                 Create a route (see --help for args)"
  echo "              delete ID/NAME              Delete a route by ID or name"
  echo
  echo "  setup-keys  list [ID/NAME]              List setup keys or get a specific key by ID or name"
  echo "              create NAME [OPTIONS]       Create a setup key with the given name and options"
  echo "              update NAME [OPTIONS]       Update an existing setup key"
  echo "              revoke ID/NAME              Revoke a setup key by ID or name"
  echo "              renew ID/NAME               Renew a setup key by ID or name"
  echo "              delete ID/NAME              Delete a setup key by ID or name"
  echo
  echo "  ssh         enable PEER                 Enable ssh access for a peer"
  echo "              disable PEER                Disable ssh access for a peer"
  echo
  echo "  tokens      list [USER]                 List tokens for a specific user (default: current user)"
  echo "              create USER NAME [OPTIONS]  Create a token for a user with the given name and options"
  echo "              delete USER TOKEN           Delete a token for a user by token name or ID"
  echo
  echo "  users       list [ID/NAME]              List users or get a specific user by ID or name"
  echo
  echo "  whoami                                  Get the current user"
}

usage_create_group() {
  echo "Usage: $(basename "$0") group create NAME [PEER1 PEER2 ...]"
  echo
  echo "Options:"
  echo "  -h, --help  Show this help message and exit"
}

usage_create_network() {
  echo "Usage: $(basename "$0") network create OPTIONS"
  echo
  echo "Options:"
  echo "  -h, --help                 Show this help message and exit"
  echo "  -d, --description <str>    Description of the route"
  echo "  -n, --name <str>           Network name"
}

usage_create_network_resource() {
  echo "Usage: $(basename "$0") resource create NETWORK OPTIONS"
  echo
  echo "Options:"
  echo "  -h, --help                 Show this help message and exit"
  echo "  -d, --description <str>    Description of the route"
  echo "  -n, --name <str>           Resource name"
  echo "  -a, --address <str>        Network resource address (eg: 127.0.99.1/32)"
  echo "  -g, --groups <grp>         Group(s) to assign the resource to (can be specified multiple times)"
}

usage_create_network_router() {
  echo "Usage: $(basename "$0") router create NETWORK OPTIONS"
  echo
  echo "Options:"
  echo "  -h, --help                 Show this help message and exit"
  echo "  -p, --peer <peer>          Peer Identifier associated with route (conflicts with --peer-group)"
  echo "  -P, --peer-group <grp>     Peer Group (conflicts with --peer)"
  echo "  -m, --metric <int>         Route metric (default: 9999)"
  echo "  -M, --masquerade <bool>    Enable masquerading (default: true)"
}

usage_create_policy() {
  echo "Usage: $(basename "$0") policy create OPTIONS"
  echo
  echo "Options:"
  echo "  -h, --help                   Show this help message and exit"
  echo "  -n, --name <str>             Resource name"
  echo "  -d, --description <str>      Description of the policy"
  echo "  -e, --enabled <bool>         Enable the policy (default: true)"
  echo "  -C, --posture-checks <str>   Posture check (can be specified multiple times)"
  echo "  -r, --rule <json>            Policy rule object (can be specified multiple times)"
  echo
  echo "Policy Rule Example:"
  cat <<EOM
{
  "name": "Default",
  "description": "This is a default rule that allows connections between all the resources",
  "enabled": true,
  "action": "accept",
  "bidirectional": true,
  "protocol": "tcp",
  "ports": [ "80" ],
  "port_ranges": [ { "start": 80, "end": 320 } ],
  "id": "ch8i4ug6lnn4g9hqv7mg",
  "sources": [ "ch8i4ug6lnn4g9hqv797" ],
  "destinations": [ "ch8i4ug6lnn4g9h7v7m0" ]
}
EOM
}

usage_create_setup_key() {
  echo "Usage: $(basename "$0") setup-key create NAME [OPTIONS]"
  echo
  echo "Options:"
  echo "  -h, --help               Show this help message and exit"
  echo "  -g, --auto-groups <grp>  Auto-add peers to this group (can be specified multiple times)"
  echo "  -E, --expires <time>     Expiration time in seconds (default: never)"
  echo "  -e, --ephemeral <bool>   Ephemeral setup key (default: false)"
  echo "  -l, --usage-limit <int>  Usage limit count (default: 0, ie. infinite)"
  echo "  -r, --revoked <bool>     Whether to revoke the key (default: false)"
  echo "  -t, --type <type>        Setup key type (reusable or one-off)"
}

usage_create_route() {
  echo "Usage: $(basename "$0") route create OPTIONS"
  echo
  echo "Options:"
  echo "  -h, --help                 Show this help message and exit"
  echo "  -d, --description <str>    Description of the route"
  echo "  -i, --network-id <str>     Network ID (name, max 40 chars)"
  echo "  -e, --enabled <bool>       Enable the route (default: true)"
  echo "  -m, --metric <int>         Route metric (default: 9999)"
  echo "  -M, --masquerade <bool>    Enable masquerading (default: true)"
  echo "  -n, --network <cidr>       Network CIDR"
  echo "  -g, --routing-group <grp>  Routing peer group(s), can be specified multiple times"
  echo "  -D, --dist-group <grp>     Distribution group(s), can be specified multiple times"
}

usage_create_token() {
  echo "Usage: $(basename "$0") token create USER NAME [OPTIONS]"
  echo
  echo "Options:"
  echo "  -h, --help            Show this help message and exit"
  echo "  -E, --expires <int>   Expiration time in days (default: 365)"
}

echo_info() {
  echo -e "\e[1m\e[34mINF\e[0m $*" >&2
}

echo_success() {
  echo -e "\e[1m\e[32mOK\e[0m $*" >&2
}

echo_warning() {
  [[ -n "$NO_WARNINGS" ]] && return 0
  echo -e "\e[1m\e[33mWRN\e[0m $*" >&2
}

echo_error() {
  echo -e "\e[1m\e[31mERR\e[0m $*" >&2
}

echo_debug() {
  [[ -z "${DEBUG}${VERBOSE}" ]] && return 0
  echo -e "\e[1m\e[35mDBG\e[0m $*" >&2
}

echo_dryrun() {
  echo -e "\e[1m\e[35mDRY\e[0m $*" >&2
}

arr_to_json() {
  printf '%s\n' "$@" | jq -cRn '[inputs]'
}

nb_cli_load_config() {
  local -a config_files=()

  local user_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/netbird-cli"
  if [[ -d "$user_config_dir" ]]
  then
    local path
    for path in "$user_config_dir"/*.env
    do
      [[ -e "$path" ]] || continue
      config_files+=("$path")
    done
  fi

  if [[ -d /etc/netbird-cli ]]
  then
    local path
    for path in /etc/netbird-cli/*.env
    do
      [[ -e "$path" ]] || continue
      config_files+=("$path")
    done
  fi

  local config_env="${NB_CLI_CONFIG_FILE:-}"
  if [[ -n "$config_env" ]]
  then
    config_files+=("$config_env")
  fi

  local -a args=("$@")
  local i=0
  while (( i < ${#args[@]} ))
  do
    local arg="${args[i]}"
    case "$arg" in
      --debug)
        DEBUG=1
        ;;
      --trace)
        DEBUG=1
        set -x
        ;;
      --config=*)
        config_files+=("${arg#--config=}")
        ;;
      --config)
        if (( i + 1 >= ${#args[@]} ))
        then
          echo_error "--config requires a file path"
          return 1
        fi
        config_files+=("${args[i+1]}")
        ((i++))
        ;;
    esac
    ((i++))
  done

  for path in "${config_files[@]}"
  do
    if [[ -f "$path" ]]
    then
      echo_debug "Loading config: $path"
      # shellcheck disable=SC1090
      source "$path"
    else
      echo_warning "Config not found: $path"
    fi
  done

  return 0
}

column() {
  if type -P column &>/dev/null
  then
    command column "$@"
    return "$?"
  fi

  fake_column "$@"
}

fake_column() {
  local separator=$'\t'
  local table_mode=
  local -a files=()

  while [[ $# -gt 0 ]]
  do
    case "$1" in
      -s)
        if [[ -z "${2:-}" ]]
        then
          echo_error "fake_column: missing argument for -s"
          return 1
        fi
        separator="$2"
        shift 2
        ;;
      -t)
        table_mode=1
        shift
        ;;
      --)
        shift
        files+=("$@")
        break
        ;;
      -*)
        echo_error "fake_column: unsupported option '$1'"
        return 1
        ;;
      *)
        files+=("$1")
        shift
        ;;
    esac
  done

  if [[ -z "$table_mode" ]]
  then
    echo_error "fake_column: only supports -t"
    return 1
  fi

  case "$separator" in
    "\\t")
      separator=$'\t'
      ;;
    "\\n")
      separator=$'\n'
      ;;
  esac

  awk \
    -v FS="$separator" \
    -v sep_out="  " \
    '
      function display_width(str, copy) {
        copy = str
        gsub(/\033\[[0-9;]*m/, "", copy)
        return length(copy)
      }

      {
        if (NF > max_nf) {
          max_nf = NF
        }

        row_fields[NR] = NF

        for (i = 1; i <= NF; ++i) {
          field = $i
          data[NR, i] = field

          len = display_width(field)
          if (len > width[i]) {
            width[i] = len
          }
        }
      }

      END {
        for (r = 1; r <= NR; ++r) {
          current_nf = row_fields[r]
          if (current_nf == 0) {
            print ""
            continue
          }

          for (c = 1; c <= max_nf; ++c) {
            field = data[r, c]

            if (c < max_nf) {
              pad = width[c] - display_width(field)
              printf "%s", (field == "" ? "" : field)
              while (pad-- > 0) {
                printf " "
              }
              printf "%s", sep_out
            } else {
              printf "%s", (field == "" ? "" : field)
            }
          }

          printf "\n"
        }
      }
    ' \
    "${files[@]}"
}

to_bool() {
  case "$1" in
    true|t|1|yes|on|y)
      echo true
      ;;
    *)
      echo false
      ;;
  esac
}

# shellcheck disable=SC2120
colorizecolumns() {
  if [[ -n "$NO_COLOR" ]]
  then
    cat
    return "$?"
  fi

   # Our rainbow of colors for each column
  local colors=(
    $'\033[36m'  # cyan
    $'\033[32m'  # green
    $'\033[35m'  # magenta
    $'\033[37m'  # white
    $'\033[33m'  # yellow
    $'\033[34m'  # blue
    $'\033[38m'  # gray
    $'\033[31m'  # red
  )
  local reset=$'\033[0m'
  local bold_red=$'\033[1;31m'
  local bold_green=$'\033[1;32m'

  awk \
    -v reset="$reset" \
    -v col_colors="${colors[*]}" \
    -v bold_green="$bold_green" \
    -v bold_red="$bold_red" \
    '
      BEGIN {
        # split on space char
        n = split(col_colors, colors, " ")
      }

      {
        # split on tabs
        nfields = split($0, fields, "\t")

        # colorize each field
        for (i = 1; i <= nfields; i++){
          fieldVal = fields[i]

          # If value == "false", highlight it in bold red
          # NOTE this will wrongly color items that are literally named "false"
          if (fieldVal == "false") {
            fields[i] = bold_red "FALSE" reset # uppercase for visibility
          } else if (fieldVal == "true") {
            fields[i] = bold_green "TRUE" reset # uppercase for visibility
          } else {
            # color based on column index
            colorIndex = (i - 1) % n
            color = colors[colorIndex+1]
            fields[i] = color fieldVal reset
          }
        }

        # reassemble line
        line = fields[1]
        for (i = 2; i <= nfields; i++) {
          line = line "\t" fields[i]
        }

        print line
      }
    '
}

curl() {
  echo_debug "\$ curl ${*@Q}"
  command curl "$@"
}

nb_curl() {
  local endpoint="$1"
  shift
  local url="${NB_MANAGEMENT_URL}/api/${endpoint}"

  curl -fsSL --retry "$RETRIES" --retry-all-errors \
    -H "Authorization: Token $NB_API_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$@" \
    "$url"
}

# Check whether a provided string is a NetBird ID
is_nb_id() {
  local thing="$1"

  # setup-key ids are just numbers. eg: 12345678
  if [[ "$thing" =~ ^[0-9]+$ ]]
  then
    return 0
  fi

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

nb_prettify_events_json() {
  local groups
  groups=$(nb_list_groups)

  if [[ -z "$groups" ]]
  then
    echo_error "Failed to list groups"
    return 1
  fi

  jq -er --argjson group_data "$groups" '
    map(. | . + {
      meta_str: (

        # Setup key added
        if (.activity_code == "setupkey.group.add")
        then
          .meta.setupkey + " -> grp: " + .meta.group

        # Peer registered using setup key
        elif (.activity_code == "setupkey.peer.add")
        then
          .meta.name + " used key " + .meta.setup_key_name

        # Route added/deleted/updated
        elif (.activity_code | test("^route."))
        then
          # TODO Resolve group names
          # NOTE The groups are not really JSON data
          # eg: "peer_groups": "[cp30j3fopoau27orerrg]"
          # -> note the missing quotes around the group ID
          # (.meta.peer_groups | fromjson) as $peer_grps |
          .meta.network_range + " via " + .meta.peer_groups

        # Unknown activity, just try to extract the name property
        else
          if (.meta | has("name"))
          then
            .meta.name
          else
            ""
          end
        end
      )
    })
  '
}

# https://docs.netbird.io/api/resources/groups#list-all-groups
# shellcheck disable=SC2120
nb_list_groups() {
  local endpoint="groups"

  if [[ -n "$1" ]]
  then
    if is_nb_id "$1"
    then
      endpoint+="/${1}"
    else
      local group_id
      group_id=$(nb_group_id "$1")

      if [[ -z "$group_id" ]]
      then
        echo_error "Failed to determine group ID of '$1'"
        return 1
      fi

      endpoint+="/${group_id}"
    fi
  fi

  nb_curl "$endpoint"
}

# Get the group ID, given the group name
nb_group_id() {
  local group="$1"

  if is_nb_id "$group"
  then
    echo "$group"
    return 0
  fi

  nb_list_groups | jq -er --arg group "$group" '
    .[] | select(.name == $group) | .id
  '
}

# Usage:
#   nb_resolve OBJECT_TYPE KEY1 KEY2 KEY3 ...
#
# Example:
#   nb_resolve group auto_groups groups peer_groups <<< "$JSON_DATA"
#
# This reads JSON from stdin and replaces each ID in the given KEY fields
# with the full object data. If the objects share a .name field (like groups do),
# you can easily invert the mapping (ID <-> name) by adjusting the logic below.
nb_resolve() {
  local object_type="$1"
  shift

  if [[ -z "$object_type" ]]
  then
    echo_error "Usage: nb_resolve OBJECT_TYPE KEY1 [KEY2 ...] <<< \$JSON_DATA"
    return 1
  fi

  # The remaining positional parameters are the JSON keys to transform
  local keys=("$@")

  echo_debug "Resolving with nb_list_${object_type} - keys: ${keys[*]}"

  # Fetch the object list JSON (similar to 'nb_list_groups' but for generic objects)
  # Make sure you have a corresponding nb_list_<object_type> for each object_type.
  local objects
  objects="$("nb_list_${object_type}")"

  echo_debug "Resolved $object_type: $objects"

  if [[ -z "$objects" ]]
  then
    echo_error "Failed to list objects for type '$object_type'"
    return 1
  fi

  local keys_json
  keys_json="$(arr_to_json "${keys[@]}")"

  echo_debug "Resolving '$object_type' for keys: $keys_json"

  # Use jq to transform each object in the JSON received via stdin.
  # This example mimics your previous logic, building two maps:
  #   1) object_map_by_id => key=.id, value=(entire object)
  #   2) object_map_by_name => key=.name, value=.id
  # Then for each item in the list we replace IDs with the entire object
  # by iterating over the specified JSON keys in "keys_json".
  jq -er \
    --argjson keys       "$keys_json" \
    --argjson objectData "$objects"   '
      def object_map_by_id:
        ($objectData | map({ key: .id, value: . }) | from_entries);

      def object_map_by_name:
        ($objectData | map({ key: .name, value: .id }) | from_entries);

      def process_fields(obj; attrs; map_id):
        reduce attrs[] as $attr (
          obj;
          if has($attr)
          then
            .[$attr] = (
              if (.[ $attr ] | type) == "array" and all(.[ $attr ][]; type == "string")
              then
                # Array of string IDs -> replace each ID with the full object (if found)
                .[$attr] | map( map_id[.] // . )
              elif (.[ $attr ] | type) == "string"
              then
                # Single string ID -> replace with the full object if found, else leave as is
                ( map_id[ (.[ $attr]) ] // .[$attr] )
              else
                # For anything else (empty string, object, null, etc.), leave as is
                .[$attr]
              end
            )
          else
            .
          end
        );

      map(
        process_fields(.; $keys; object_map_by_id)
      )
    '
}

# shellcheck disable=SC2120
nb_resolve_lazy() {
  # The user can specify a "key", defaulting to "all".
  local key="${1:-all}"

  # Look up the comma-separated list in OBJECT_RESOLVERS
  local resolvers="${OBJECT_RESOLVERS[$key]}"

  # If no entry in the map, fallback or do nothing
  if [[ -z "$resolvers" ]]
  then
    echo_debug "No resolvers mapped for key=$key; skipping resolution."
    cat  # just pass through
    return 0
  fi

  echo_debug "Running resolvers for key=$key: $resolvers"

  # Split the comma list into an array
  local items
  IFS=',' read -ra items <<< "$resolvers"

  # We'll read JSON from stdin and apply each resolver in turn
  local data
  data="$(cat)"

  local resolver
  for resolver in "${items[@]}"
  do
    case "$resolver" in
      groups)
        data="$(nb_resolve_groups <<< "$data")"
        ;;
      network_routers)
        data="$(nb_resolve_network_routers <<< "$data")"
        ;;
      network_resources)
        data="$(nb_resolve_network_resources <<< "$data")"
        ;;
      *)
        echo_warning "Unknown resolver '$resolver'; skipping"
        ;;
    esac
  done

  # Output the final result
  printf '%s\n' "$data"
}

nb_resolve_groups() {
  nb_resolve groups \
    auto_groups groups peer_groups
}

nb_resolve_network_routers() {
  nb_resolve network_routers routers
}

nb_resolve_network_resources() {
  nb_resolve network_resources resources
}

# https://docs.netbird.io/api/resources/groups#create-a-group
# Usage: nb_create_group NAME [PEER1 PEER2 ...]
nb_create_group() {
  if [[ -z "$1" ]]
  then
    usage_create_group >&2
    return 2
  fi

  local name="$1"
  shift

  local peers=("$@")
  local peers_json="null"

  if [[ ${#peers[@]} -gt 0 ]]
  then
    local -a resolved_peers
    local p

    for p in "${peers[@]}"
    do
      resolved_peers+=("$(nb_peer_id "$p")")
    done

    peers_json=$(arr_to_json "${resolved_peers[@]}")
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
    echo_error "Missing group ID/name"
    return 2
  fi

  if ! is_nb_id "$group"
  then
    group_id=$(nb_group_id "$group")

    if [[ -z "$group_id" ]]
    then
      echo_error "Failed to determine group ID of '$group'"
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
# https://docs.netbird.io/api/resources/peers#retrieve-a-peer
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
        echo_error "Failed to determine peer ID of '$1'"
        return 1
      fi

      if [[ $(wc -l <<< "$peer_id") -eq 1 ]]
      then
        endpoint+="/${peer_id}"
      else
        echo_warning "Multiple peers found with the name '$1'"

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

nb_get_peer() {
  local peer="$1"

  if ! peer_data=$(nb_list_peers "$peer")
  then
    echo_error "Failed to retrieve peer data for '$peer'"
    return 1
  fi

  if jq -e 'type == "array"' &>/dev/null <<< "$peer_data"
  then
    local count
    count=$(jq -er 'length' <<< "$peer_data")

    if [[ "$count" -eq 1 ]]
    then
      peer_data=$(jq -er '.[0]' <<< "$peer_data")
    else
      echo_error "Multiple peers matched '$peer' — please use an ID or unique hostname"
      return 2
    fi
  fi

  printf '%s\n' "$peer_data"
}

nb_update_peer() {
  local peer
  local name
  local ssh
  local login
  local inact

  while [[ -n "$1" ]]
  do
    case "$1" in
      --name)
        name="$2"
        shift 2
        ;;
      --ssh-enabled)
        ssh="true"
        shift
        ;;
      --ssh-disabled|--no-ssh|--ssh-disable)
        ssh="false"
        shift
        ;;
      --ssh)
        ssh="$(to_bool "$2")"
        shift 2
        ;;
      --login-expiration-enabled)
        login="true"
        shift
        ;;
      --login-expiration-disabled|--no-login-expiration)
        login="false"
        shift
        ;;
      --login-expiration)
        login="$(to_bool "$2")"
        shift 2
        ;;
      --inactivity-expiration-enabled)
        inact="true"
        shift
        ;;
      --inactivity-expiration-disabled|--no-inactivity-expiration)
        inact="false"
        shift
        ;;
      --inactivity-expiration)
        inact="$(to_bool "$2")"
        shift 2
        ;;
      -*)
        echo_error "Unknown option for peer update: $1"
        return 2
        ;;
      *)
        peer="$1"
        shift
        break
        ;;
    esac
  done

  if [[ -z "$peer" ]]
  then
    echo_error "Missing peer ID/name"
    return 2
  fi

  local peer_data
  if ! peer_data=$(nb_get_peer "$peer")
  then
    echo_error "Failed to retrieve peer data for '$peer'"
    return 1
  fi

  local peer_id
  if ! peer_id=$(jq -er '.id' <<< "$peer_data")
  then
    echo_error "Failed to determine peer ID of '$peer'"
    echo_debug "peer data: ${peer_data}"
    return 1
  fi

  if [[ -z "$name" && -z "$ssh" && -z "$login" && -z "$inact" ]]
  then
    echo_warning "No update flags provided; nothing to do for ${peer_id}"
    return 0
  fi

  local updated
  if ! updated=$(jq -er \
    --arg name "$name" \
    --arg ssh "$ssh" \
    --arg login "$login" \
    --arg inact "$inact" '
      .
      | (
        if ($name | length) > 0
        then
          .name = $name
         end
      )

      | (
        if ($ssh | length) > 0
        then
          .ssh_enabled = ($ssh == "true")
        end
      )

      | (
        if ($login | length) > 0
        then (
          if .login_expiration_enabled? != null
          then
            .login_expiration_enabled = ($login == "true")
          end
        ) | (
          if .login_settings?
          then
            .login_settings.login_expiration_enabled = ($login == "true")
          end
        )
        end
      )

      | (
        if ($inact | length) > 0
        then (
          if .inactivity_expiration_enabled? != null
          then
            .inactivity_expiration_enabled = ($inact == "true")
          end
        ) | (
          if .login_settings?
          then
            .login_settings.inactivity_expiration_enabled = ($inact == "true")
          end
        )
        end
      )
    ' <<< "$peer_data")
  then
    echo_error "Failed to build updated peer JSON"
    return 1
  fi

  local endpoint="peers/${peer_id}"
  echo_info "Updating peer ${peer_id}"
  if ! nb_curl "$endpoint" -X PUT --json "$updated"
  then
    echo_error "Peer update failed"
    return 1
  fi

  echo_success "Updated peer ${peer_id}"
}

nb_peer_id() {
  local peer_name="$1"
  nb_list_peers | jq -er --arg peer_name "$peer_name" '
    .[] | select(.hostname == $peer_name) | .id
  '
}

nb_ssh_set() {
  local peer="$1"
  local enabled="$2"
  echo_debug "Setting SSH access for peer $peer to $enabled"

  local peer_data
  if ! peer_data=$(nb_list_peers "$peer")
  then
    echo_error "Failed to retrieve peer data for '$peer'"
    return 1
  fi

  local peer_id
  if ! peer_id=$(jq -er '.id' <<< "$peer_data")
  then
    echo_error "Failed to determine peer ID of '$peer'"
    echo_debug "peer data: ${peer_data}"
    return 1
  fi

  local endpoint="peers/${peer_id}"
  peer_data=$(jq -er --argjson enabled "$enabled" <<< "$peer_data" '
    .ssh_enabled = $enabled
  ')

  nb_curl "$endpoint" -X PUT --json "$peer_data"
}

nb_ssh_enable() {
  local peer="$1"
  echo_info "Enabling SSH access for peer $peer"
  if ! nb_ssh_set "$peer" true | jq -er '.ssh_enabled == true' >/dev/null
  then
    echo_error "Failed to enable SSH access for peer $peer"
    return 1
  fi

  echo_success "Enabled SSH access to $peer"
}

nb_ssh_disable() {
  local peer="$1"
  echo_info "Disabling SSH access for peer $peer"
  if ! nb_ssh_set "$peer" false | jq -er '.ssh_enabled == false' >/dev/null
  then
    echo_error "Failed to enable SSH access for peer $peer"
    return 1
  fi

  echo_success "Disabled SSH access to $peer"
}

# https://docs.netbird.io/api/resources/policies#list-all-policies
# https://docs.netbird.io/api/resources/policies#retrieve-a-policy
# shellcheck disable=SC2120
nb_list_policies() {
  local endpoint="policies"

  if [[ -n "$1" ]]
  then
    if is_nb_id "$1"
    then
      endpoint+="/${1}"
    else
      local policy_id
      policy_id=$(nb_policy_id "$1")

      if [[ -z "$policy_id" ]]
      then
        echo_error "Failed to determine posture check ID of '$1'"
        return 1
      fi

      endpoint+="/${policy_id}"
    fi
  fi

  nb_curl "$endpoint"
}

nb_policy_id() {
  local policy_name="$1"
  nb_list_policies | jq -er --arg policy_name "$policy_name" '
    .[] | select(.name == $policy_name) | .id
  '
}

# https://docs.netbird.io/api/resources/policies#create-a-policy
nb_create_policy() {
  local args

  local name
  local description
  local enabled=true
  local source_posture_checks
  local rules_json='[]'
  local rule

  while [[ -n "$*" ]]
  do
    case "$1" in
      -h|--help|-\?)
        usage_create_policy
        return 0
        ;;
      -n|--name)
        name="$2"
        shift 2
        ;;
      -d|--description)
        description="$2"
        shift 2
        ;;
      -p|--posture-checks|--source-posture-checks)
        source_posture_checks+=("$2")
        shift 2
        ;;
      -r|--rule|--rules)
        rule="$2"

        if [[ "$rule" == @* ]]
        then
          if ! rule=$(cat "${rule#@}")
          then
            echo_error "Failed to read rule file ${rule#@}"
            return 1
          fi
        fi

        # TODO Make this more user-friendly
        if ! rules_json=$(jq -er --argjson rule "$rule" \
          '. + [$rule]' <<< "$rules_json")
        then
          echo_error "Invalid rules JSON provided"
          return 2
        fi
        shift 2
        ;;
      # same as above, but explicitly reads from file
      --rule-file|--rules-file)
        rule="$2"

        if ! rule=$(cat "$rule")
        then
          echo_error "Failed to read rule file $rule"
          return 1
        fi

        if ! rules_json=$(jq -er --argjson rule "$rule" \
          '. + [$rule]' <<< "$rules_json")
        then
          echo_error "Invalid rules JSON provided"
          return 2
        fi
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  set -- "${args[@]}"

  if [[ -z "$name" || "$rules_json" == '[]' ]]
  then
    echo_error "Missing required arguments (name and rules are required)"
    return 1
  fi

  # Resolve posture checks
  local -a resolved_posture_checks
  local posture_checks_json='[]'
  if [[ "${#source_posture_checks[@]}" -gt 0 ]]
  then
    local pc
    for pc in "${source_posture_checks[@]}"
    do
      resolved_posture_checks+=("$(nb_posture_check_id "$pc")")
    done

    posture_checks_json=$(arr_to_json "${resolved_posture_checks[@]}")
  fi

  # Resolve groups in rules
  local rules_json_resolved
  rules_json_resolved=$(nb_resolve_groups --inverse \
    -k sources \
    -k destinations \
    <<< "$rules_json")

  echo_info "Creating policy $name"

  local data
  data=$(jq -Rcsn \
    --arg name "$name" \
    --arg description "$description" \
    --argjson enabled "$enabled" \
    --argjson source_posture_checks "$posture_checks_json" \
    --argjson rules "$rules_json_resolved" \
    '
      {
        name: $name,
        description: $description,
        enabled: $enabled,
        source_posture_checks: $source_posture_checks,
        rules: $rules
      }
    ')

  nb_curl policies -X POST --data-raw "$data"
}

# https://docs.netbird.io/api/resources/policies#delete-a-policy
# shellcheck disable=SC2317
nb_delete_policy() {
  local policy="$1"

  if [[ -z "$policy" ]]
  then
    echo_error "Missing policy ID/name"
    return 2
  fi

  if ! is_nb_id "$policy"
  then
    policy_id=$(nb_policy_id "$policy")

    if [[ -z "$policy_id" ]]
    then
      echo_error "Failed to determine policy ID of '$policy'"
      return 1
    fi

    policy="$policy_id"
  fi

  echo_info "Deleting policy $policy"
  nb_curl "policies/${policy}" -X DELETE
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
        echo_error "Failed to determine posture check ID of '$1'"
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

# https://docs.netbird.io/api/resources/networks#list-all-networks
# shellcheck disable=SC2120
nb_list_networks() {
  local endpoint="networks"

  if [[ -n "$1" ]]
  then
    if is_nb_id "$1"
    then
      endpoint+="/${1}"
    else
      local network_id
      network_id=$(nb_network_id "$1")

      if [[ -z "$network_id" ]]
      then
        echo_error "Failed to determine network ID of '$1'"
        return 1
      fi

      endpoint+="/${network_id}"
    fi
  fi

  local data
  if ! data=$(nb_curl "$endpoint")
  then
    echo_error "Failed to list networks"
    return 1
  fi

  printf '%s\n' "$data"
  return 0
}

# https://docs.netbird.io/api/resources/networks#create-a-network
nb_create_network() {
  local args

  local description
  local name # max 40 chars?

  while [[ -n "$*" ]]
  do
    case "$1" in
      -h|--help|-\?)
        usage_create_network
        return 0
        ;;
      -d|--description)
        description="$2"
        shift 2
        ;;
      -n|--name)
        name="$2"
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  set -- "${args[@]}"

  local data
  data=$(jq -Rcsn \
    --arg name "$name" \
    --arg description "$description" \
    '
      {
        name: $name,
        description: $description
      }
    ')

  nb_curl networks -X POST --data-raw "$data"
}

# https://docs.netbird.io/api/resources/networks#list-all-network-resources
# shellcheck disable=SC2120
nb_list_network_resources() {
  local endpoint="networks"

  if [[ -z "$1" ]]
  then
    # echo_error "Missing network ID/name"
    # return 2
    local net net_id
    local networks
    mapfile -t networks < <(nb_list_networks | jq -cer '.[]')

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" EXIT

    for net in "${networks[@]}"
    do
      # Recurse over all
      if ! net_id=$(jq -er '.id' <<< "$net")
      then
        echo_warning "Failed to determine network ID of '$net'"
        continue
      fi

      {
        nb_list_network_resources "$net_id" | {
          if [[ -n "$VERBATIM" ]]
          then
            cat
          else
            jq --argjson net "$net" '.[].network = $net'
          fi
        }
      } > "${tmpdir}/${net_id}.json" &
    done
    wait

    jq -es add "${tmpdir}"/*.json
    return "$?"
  fi

  if is_nb_id "$1"
  then
    endpoint+="/${1}"
  else
    local network_id
    network_id=$(nb_network_id "$1")

    if [[ -z "$network_id" ]]
    then
      echo_error "Failed to determine network ID of '$1'"
      return 1
    fi

    endpoint+="/${network_id}"
  fi

  endpoint+="/resources"

  if [[ -n "$2" ]]
  then
    if is_nb_id "$2"
    then
      endpoint+="/${2}"
    else
      local res_id
      res_id=$(nb_network_resource_id "$1" "$2")

      if [[ -z "$res_id" ]]
      then
        echo_error "Failed to determine network resource ID of '$2'"
        return 1
      fi

      endpoint+="/${res_id}"
    fi
  fi

  local data
  if ! data=$(nb_curl "$endpoint")
  then
    echo_error "Failed to list network resources"
    return 1
  fi

  printf '%s\n' "$data"
  return 0
}

# https://docs.netbird.io/api/resources/networks#create-a-network-resource
nb_create_network_resource() {
  local args
  local network="$1"

  # resolve network id
  if ! is_nb_id "$network"
  then
    local network_id
    network_id=$(nb_network_id "$network")

    if [[ -z "$network_id" ]]
    then
      echo_error "Failed to determine network ID of '$network'"
      return 1
    fi

    network="$network_id"
  fi

  local address
  local description
  local groups
  local name

  while [[ -n "$*" ]]
  do
    case "$1" in
      -h|--help|-\?)
        usage_create_network_resource
        return 0
        ;;
      -d|--description)
        description="$2"
        shift 2
        ;;
      -n|--name)
        name="$2"
        shift 2
        ;;
      -a|--address)
        address="$2"
        shift 2
        ;;
      -g|--group*)
        groups+=("$2")
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  set -- "${args[@]}"

  # Resolve groups
  local -a resolved_groups
  local groups_json=null

  if [[ "${#groups[@]}" -gt 0 ]]
  then
    local g
    for g in "${groups[@]}"
    do
      resolved_groups+=("$(nb_group_id "$g")")
    done

    groups_json=$(arr_to_json "${resolved_groups[@]}")
  fi

  local data
  data=$(jq -Rcsn \
    --arg name "$name" \
    --arg description "$description" \
    --arg address "$address" \
    --argjson groups "$groups_json" \
    '
      {
        name: $name,
        description: $description,
        address: $address,
        groups: $groups,
      }
    ')

  nb_curl "networks/${network}/resources" -X POST --data-raw "$data"
}

nb_delete_network_resource() {
  local network="$1"
  local network_resource="$2"

  if [[ -z "$network" ]]
  then
    echo_error "Missing network ID/name"
    return 2
  fi

  if [[ -z "$network_resource" ]]
  then
    echo_error "Missing network router ID/name"
    return 2
  fi

  if ! is_nb_id "$network"
  then
    network_id=$(nb_network_id "$network")

    if [[ -z "$network_id" ]]
    then
      echo_error "Failed to determine network ID of '$network'"
      return 1
    fi

    network="$network_id"
  fi

  if ! is_nb_id "$network_resource"
  then
    network_resource_id=$(nb_network_resource_id "$network")

    if [[ -z "$network_resource_id" ]]
    then
      echo_error "Failed to determine network router ID of '$network'"
      return 1
    fi

    network_resource="$network_id"
  fi

  nb_curl "networks/${network}/routers/${network_resource}" -X DELETE
}

# https://docs.netbird.io/api/resources/networks#delete-a-network
nb_delete_network() {
  local network="$1"

  if [[ -z "$network" ]]
  then
    echo_error "Missing network ID/name"
    return 2
  fi

  if ! is_nb_id "$network"
  then
    network_id=$(nb_network_id "$network")

    if [[ -z "$network_id" ]]
    then
      echo_error "Failed to determine network ID of '$network'"
      return 1
    fi

    network="$network_id"
  fi

  echo_info "Deleting network $network"
  nb_curl "networks/${network}" -X DELETE
}

# https://docs.netbird.io/api/resources/networks#list-all-network-routers
# shellcheck disable=SC2120
nb_list_network_routers() {
  local endpoint="networks"

  if [[ -z "$1" ]]
  then
    # echo_error "Missing network ID/name"
    # return 2
    local net net_id
    local networks
    mapfile -t networks < <(nb_list_networks | jq -cer '.[]')

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" EXIT

    for net in "${networks[@]}"
    do
      # Recurse over all
      if ! net_id=$(jq -er '.id' <<< "$net")
      then
        echo_warning "Failed to determine network ID of '$net'"
        continue
      fi
      {
        nb_list_network_routers "$net_id" | {
          if [[ -n "$VERBATIM" ]]
          then
            cat
          else
            jq --argjson net "$net" '
              [
                .[] |
                .network = $net |
                .name = (.id  + "@" + $net.name)
              ]
            '
          fi
        }
      } > "${tmpdir}/${net_id}.json" &
    done
    wait

    jq -es add "${tmpdir}"/*.json
    return "$?"
  fi

  if is_nb_id "$1"
  then
    endpoint+="/${1}"
  else
    local network_id
    network_id=$(nb_network_id "$1")

    if [[ -z "$network_id" ]]
    then
      echo_error "Failed to determine network ID of '$1'"
      return 1
    fi

    endpoint+="/${network_id}"
  fi

  endpoint+="/routers"

  if [[ -n "$2" ]]
  then
    if is_nb_id "$2"
    then
      endpoint+="/${2}"
    else
      local res_id
      res_id=$(nb_network_router_id "$1" "$2")

      if [[ -z "$res_id" ]]
      then
        echo_error "Failed to determine network router ID of '$2'"
        return 1
      fi

      endpoint+="/${res_id}"
    fi
  fi

  local data
  if ! data=$(nb_curl "$endpoint")
  then
    echo_error "Failed to list network routers"
    return 1
  fi

  printf '%s\n' "$data"
  return 0
}

# https://docs.netbird.io/api/resources/networks#create-a-network-router
nb_create_network_router() {
  local args
  local network="$1"

  # resolve network id
  if ! is_nb_id "$network"
  then
    local network_id
    network_id=$(nb_network_id "$network")

    if [[ -z "$network_id" ]]
    then
      echo_error "Failed to determine network ID of '$network'"
      return 1
    fi

    network="$network_id"
  fi

  local peer="null"
  local peer_groups="null"
  local metric=9999 # >=1 && <=9999
  local masq=true

  while [[ -n "$*" ]]
  do
    case "$1" in
      -h|--help|-\?)
        usage_create_network_router
        return 0
        ;;
      -m|--metric)
        metric="$2"
        shift 2
        ;;
      -M|--masq*)
        masq=$(to_bool "$2")
        shift 2
        ;;
      -p|--peer)
        peer="$2"
        shift 2
        ;;
      -g|--group*|--peer-group*)
        groups+=("$2")
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  set -- "${args[@]}"

  # Resolve groups
  local -a resolved_groups
  local groups_json=null

  if [[ "${#groups[@]}" -gt 0 ]]
  then
    local g
    for g in "${groups[@]}"
    do
      resolved_groups+=("$(nb_group_id "$g")")
    done

    groups_json=$(arr_to_json "${resolved_groups[@]}")
  fi

  local data
  data=$(jq -Rcsn \
    --argjson metric "$metric" \
    --argjson masquerade "$masq" \
    --argjson peer "$peer" \
    --argjson groups "$groups_json" \
    '
      {
        metric: $metric,
        masquerade: $masquerade,
        peer: $peer,
        peer_groups: $groups,
      }
    ')

  nb_curl "networks/${network}/routers" -X POST --data-raw "$data"
}

# https://docs.netbird.io/api/resources/networks#delete-a-network-router
nb_delete_network_router() {
  local network="$1"
  local network_router="$2"

  if [[ -z "$network" ]]
  then
    echo_error "Missing network ID/name"
    return 2
  fi

  if ! is_nb_id "$network"
  then
    network_id=$(nb_network_id "$network")

    if [[ -z "$network_id" ]]
    then
      echo_error "Failed to determine network ID of '$network'"
      return 1
    fi

    network="$network_id"
  fi

  if [[ -z "$network_router" ]]
  then
    echo_error "Missing network router ID/name"
    return 2
  fi

  if ! is_nb_id "$network_router"
  then
    network_router_id=$(nb_network_router_id "$network")

    if [[ -z "$network_router_id" ]]
    then
      echo_error "Failed to determine network router ID of '$network'"
      return 1
    fi

    network_router="$network_id"
  fi

  nb_curl "networks/${network}/routers/${network_router}" -X DELETE
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
        echo_error "Failed to determine route ID of '$1'"
        return 1
      fi

      endpoint+="/${route_id}"
    fi
  fi

  local data
  if ! data=$(nb_curl "$endpoint")
  then
    echo_error "Failed to list routes"
    return 1
  fi

  if [[ -n "$NO_HACKS" ]]
  then
    printf '%s\n' "$data"
    return 0
  fi

  # FIX for netbird's API return a static .network set to 192.168.2.0/32 for
  # DNS routes
  printf '%s\n' "$data" | \
    jq -er '
      .[] | .network = (
        if .domains != null
        then
          .domains
        else
          .network
        end
      )'
}

nb_route_id() {
  local network_id="$1"
  nb_list_routes | jq -er --arg network_id "$network_id" '
    .[] | select(.network_id == $network_id) | .id
  '
}

nb_network_id() {
  local net="$1"
  nb_list_networks | jq -er --arg net "$net" '
    .[] | select(.id == $net or .name == $net) | .id
  '
}

nb_network_resource_id() {
  local network="$1"
  local res="$2"
  nb_list_network_resources "$network" | jq -er --arg res "$res" '
    .[] | select(.id == $res or .name == $res) | .id
  '
}

nb_network_router_id() {
  local network="$1"
  local router="$2"
  nb_list_network_routers "$network" | jq -er --arg router "$router" '
    .[] | select(.id == $router or .name == $router) | .id
  '
}

# https://docs.netbird.io/api/resources/routes#create-a-route
nb_create_route() {
  local args

  local description
  local network_id  # max 40 chars
  local enabled=true
  local -a dist_groups peer_groups
  local metric
  local cidr
  local masq=true
  local metric=9999

  while [[ -n "$*" ]]
  do
    case "$1" in
      -h|--help|-\?)
        usage_create_route
        return 0
        ;;
      -d|--description)
        description="$2"
        shift 2
        ;;
      -i|--network-id)
        network_id="$2"
        shift 2
        ;;
      -e|--enabled)
        enabled=$(to_bool "$2")
        shift 2
        ;;
      -m|--metric)
        metric="$2"
        shift 2
        ;;
      -M|--masq*)
        masq=$(to_bool "$2")
        shift 2
        ;;
      -n|--network|--cidr)
        cidr="$2"
        shift 2
        ;;
      -g|--group*|--routing*group) # routing peers
        peer_groups+=("$2")
        shift 2
        ;;
      -D|--dist*) # distribution group
        dist_groups+=("$2")
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  set -- "${args[@]}"

  local -a resolved_groups
  local g

  local dist_groups_json=null
  if [[ "${#dist_groups[@]}" -gt 0 ]]
  then
    # Resolve groups
    for g in "${dist_groups[@]}"
    do
      resolved_groups+=("$(nb_group_id "$g")")
    done
    dist_groups_json=$(arr_to_json "${resolved_groups[@]}")
    # Reset array
    resolved_groups=()
  fi

  local peer_groups_json=null
  if [[ "${#peer_groups[@]}" -gt 0 ]]
  then
    # Resolve groups
    for g in "${peer_groups[@]}"
    do
      resolved_groups+=("$(nb_group_id "$g")")
    done
    peer_groups_json=$(arr_to_json "${resolved_groups[@]}")
  fi

  local data
  data=$(jq -Rcsn \
    --arg network_id "$network_id" \
    --arg description "$description" \
    --arg network "$cidr" \
    --argjson peer_groups "$peer_groups_json" \
    --argjson groups "$dist_groups_json" \
    --argjson metric "$metric" \
    --argjson masquerade "$masq" \
    --argjson enabled "$enabled" '
      {
        description: $description,
        network_id: $network_id,
        enabled: $enabled,
        peer_groups: $peer_groups,
        network: $network,
        metric: $metric,
        masquerade: $masquerade,
        groups: $groups,
      }
    ')

  nb_curl routes -X POST --data-raw "$data"
}

# https://docs.netbird.io/api/resources/routes#delete-a-route
nb_delete_route() {
  local route="$1"

  if [[ -z "$route" ]]
  then
    echo_error "Missing route ID/name"
    return 2
  fi

  if ! is_nb_id "$route"
  then
    route_id=$(nb_route_id "$route")

    if [[ -z "$route_id" ]]
    then
      echo_error "Failed to determine route ID of '$route'"
      return 1
    fi

    route="$route_id"
  fi

  nb_curl "routes/${route}" -X DELETE
}

# https://docs.netbird.io/api/resources/setup-keys#list-all-setup-keys
nb_list_setup_keys() {
  local endpoint="setup-keys"
  local single

  local show_all
  case "$1" in
    -a|--all)
      show_all=1
      shift
      ;;
  esac

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
        echo_error "Failed to determine setup key ID of '$1'"
        return 1
      fi

      if [[ $(wc -l <<< "$setup_key_id") -eq 1 ]]
      then
        # FIXME This always yields 404 on 0.32.0
        # endpoint+="/${setup_key_id}"
        single=1
      else
        echo_warning "Multiple setup-keys found with name '$1'"

        local setup_key
        for setup_key in $setup_key_id
        do
          nb_list_setup_keys "$setup_key"
        done

        return "$?"
      fi
    fi
  fi

  local data
  if ! data=$(nb_curl "$endpoint")
  then
    echo_error "Failed to list setup keys"
    return 1
  fi

  if [[ -z "$show_all" ]]
  then
    if [[ -n "$single" ]]
    then
      # FIXME This was altered due to 0.32.0 always returning a 404 for individual keys
      # data=$(<<<"$data" jq -er 'select(.revoked == false)')
      data=$(<<<"$data" jq -er --arg key_id "$setup_key_id" '.[] | select(.id == $key_id and .revoked == false)')
    else
      data=$(<<<"$data" jq -er '[.[] | select(.revoked == false)]')
    fi
  fi

  printf '%s\n' "$data"
}

# https://docs.netbird.io/api/resources/setup-keys#list-all-setup-keys
nb_setup_key_id() {
  # Setup Keys IDS are 9 digits or more
  if [[ "$1" =~ ^[0-9]{9,}$ ]]
  then
    echo "$1"
    return 0
  fi

  local setup_key_name="$1"

  nb_list_setup_keys --all | jq -er --arg setup_key_name "$setup_key_name" '
    .[] | select(.name == $setup_key_name) | .id
  '
}

# https://docs.netbird.io/api/resources/setup-keys#create-a-setup-key
nb_create_setup_key() {
  local args
  local -a auto_groups
  local ephemeral="${ephemeral:-true}"
  local expires_in="${expires_in:-null}" # never
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
        ephemeral=$(to_bool "$2")
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
        revoked=$(to_bool "$2")
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
  echo_info "Creating setup key $name"

  local auto_groups_json=null
  if [[ "${#auto_groups[@]}" -gt 0 ]]
  then
    # Resolve groups
    local -a resolved_groups
    local g
    for g in "${auto_groups[@]}"
    do
      resolved_groups+=("$(nb_group_id "$g")")
    done
    auto_groups_json=$(arr_to_json "${resolved_groups[@]}")
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
nb_update_setup_key() {
  local setup_key="$1"
  shift
  local setup_key_id
  setup_key_id=$(nb_setup_key_id "$setup_key")
  if [[ -z "$setup_key_id" ]]
  then
    echo_error "Failed to determine setup key ID of '$setup_key'"
    return 1
  fi

  echo_info "Deleting setup key $setup_key_id"
  if ! nb_delete_setup_key "$setup_key_id" >/dev/null
  then
    return 1
  fi

  nb_create_setup_key "$setup_key" "$@"
}

nb_renew_setup_key() {
  local name="$1"

  local data
  data=$(nb_list_setup_keys "$name")
  if [[ -z "$data" || "$data" == "null" ]]
  then
    echo_error "Failed to retrieve setup key data of '$name'"
    return 1
  fi

  echo_debug "Setup key data: $data"

  local groups
  mapfile -t groups < <(jq -er '.auto_groups[]' <<< "$data")
  local group_args=()
  local g
  for g in "${groups[@]}"
  do
    group_args+=("--group" "$g")
  done

  nb_update_setup_key "$name" \
    --revoked false \
    --ephemeral "$(jq -er '.ephemeral' <<< "$data")" \
    --expires "$(jq -er '.expires_in' <<< "$data")" \
    --type "$(jq -er '.type' <<< "$data")" \
    --usage-limit "$(jq -er '.usage_limit' <<< "$data")" \
    "${group_args[@]}"
}

nb_revoke_setup_key() {
  local setup_key="$1"

  if [[ -z "$setup_key" ]]
  then
    echo "Missing setup_key ID/name"
    return 2
  fi

  if ! is_nb_id "$setup_key"
  then
    setup_key_id=$(nb_setup_key_id "$setup_key")

    if [[ -z "$setup_key_id" ]]
    then
      echo_error "Failed to determine setup key ID of '$setup_key'"
      return 1
    fi

    setup_key="$setup_key_id"
  fi

  local data
  data=$(nb_list_setup_keys "$setup_key" | jq -er '.revoked = true')

  if [[ -z "$data" || "$data" == "null" ]]
  then
    echo_error "Failed to retrieve setup key data of '$setup_key'"
    return 1
  fi

  nb_curl "setup-keys/${setup_key}" -X PUT --data-raw "$data"
}

# https://docs.netbird.io/api/resources/setup-keys#delete-a-setup-key
nb_delete_setup_key() {
  local setup_key="$1"

  if [[ -z "$setup_key" ]]
  then
    echo "Missing setup_key ID/name"
    return 2
  fi

  if ! is_nb_id "$setup_key"
  then
    setup_key_id=$(nb_setup_key_id "$setup_key")

    if [[ -z "$setup_key_id" ]]
    then
      echo_error "Failed to determine setup key ID of '$setup_key'"
      return 1
    fi

    setup_key="$setup_key_id"
  fi

  if nb_curl "setup-keys/${setup_key}" -X DELETE
  then
    echo_success "Deleted setup key $setup_key"
    return 0
  fi

  echo_error "Failed to delete setup key $setup_key"
  return 1
}

# https://docs.netbird.io/api/resources/tokens#list-all-tokens
nb_list_tokens() {
  local user="$1"

  if [[ -z "$user" || "$user" == "self" ]]
  then
    user=$(nb_user_id self)
  elif ! is_nb_id "$user"
  then
    local user_id
    user_id=$(nb_user_id "$user")

    if [[ -z "$user_id" ]]
    then
      echo_error "Failed to determine user ID of '$user'"
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
        echo_error "Failed to determine token ID of '$2'"
        return 1
      fi

      endpoint+="/${token_id}"
    fi
  fi

  nb_curl "$endpoint"
}

nb_token_id() {
  local user="$1"

  if [[ -z "$user" || "$user" == "self" ]]
  then
    user=$(nb_user_id self)
  elif ! is_nb_id "$user"
  then
    local user_id
    user_id=$(nb_user_id "$user")

    if [[ -z "$user_id" ]]
    then
      echo_error "Failed to determine user ID of '$user'"
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

  if [[ -z "$user" || "$user" == "self" ]]
  then
    user=$(nb_user_id self)
  elif ! is_nb_id "$user"
  then
    local user_id
    user_id=$(nb_user_id "$user")
    if [[ -z "$user_id" ]]
    then
      echo_error "Failed to determine user ID of '$user'"
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

  if [[ -z "$user" || "$user" == "self" ]]
  then
    user=$(nb_user_id self)
  elif ! is_nb_id "$user"
  then
    local user_id
    user_id=$(nb_user_id "$user")
    if [[ -z "$user_id" ]]
    then
      echo_error "Failed to determine user ID of '$user'"
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
      echo_error "Failed to determine token ID of '$token'"
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
        echo_error "Failed to determine user ID of '$1'"
        return 1
      fi

      endpoint+="/${user_id}"
    fi
  fi

  local data
  if ! data=$(nb_curl "$endpoint")
  then
    echo_error "Failed to list users"
    return 1
  fi

  printf '%s\n' "$data"
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

pretty_output() {
  local columns_json_arr
  columns_json_arr=$(arr_to_json "${JSON_COLUMNS[@]}")

  {
    if [[ -z "$NO_HEADER" ]]
    then
      # shellcheck disable=SC2031
      for col in "${COLUMN_NAMES[@]}"
      do
        if [[ -n "$NO_COLOR" ]]
        then
          echo -ne "${col}\t"
        else
          echo -ne "\e[1m${col}\e[0m\t"
        fi
      done
      echo
    fi

    local compact=false
    [[ -n "$COMPACT" ]] && compact=true

    local sort_by=${SORT_BY:-name} sort_reverse=false
    if [[ "$sort_by" == -* ]]
    then
      sort_by="${sort_by:1}"
      sort_reverse=true
    fi

    echo_debug "sort by: $sort_by (reverse: $sort_reverse)"

    jq -er \
      --arg sort_by "$sort_by" \
      --argjson sort_reverse "$sort_reverse" \
      --argjson cols_json "$columns_json_arr" \
      --argjson compact "$compact" '
        def extractFields:
          . as $obj
          | reduce $cols_json[] as $field (
              {}
            ; . + {
                ($field | gsub("\\."; "_")):
                  $obj | getpath($field | split("."))
              }
          );

        def sortByKey(key):
          sort_by(
            ( getpath(key | split(".")) ) as $v
            | if $v | type == "string"
              then $v | ascii_downcase
              else $v
              end
          );

        "N/A" as $NA
        | if type == "array"
          then
            sortByKey($sort_by)
            | if $sort_reverse then reverse else . end
            | map(extractFields)[]
          else
            extractFields
          end
        | map(
          if (type == "null") or (type == "string" and (length == 0))
          then
            $NA
          elif type == "array"
          then
            if length == 0
            then
              $NA
            elif all(.[]; type == "object" and has("name"))
            then
              40 as $maxwidth
              | [.[].name]
              | sort
              | join(" ") as $out
              | if $compact and ($out | length) > $maxwidth
                then
                  $out[0:$maxwidth] + "…"
                else
                  $out
                end
            else
              join(", ")
            end
          else
            .
          end
        ) | @tsv
    ' | colorizecolumns
  } | column -t -s '	'
}

main() {
  if ! nb_cli_load_config "$@"
  then
    return 1
  fi
  local ARGS=()
  local ACTION=list

  # Globals!
  JSON_COLUMNS=(name)
  COLUMN_NAMES=(Name)

  while [[ -n "$*" ]]
  do
    case "$1" in
      -h|--help)
        ACTION=help
        shift
        ;;
      --debug)
        DEBUG=1
        shift
        ;;
      --trace)
        DEBUG=1
        set -x
        shift
        ;;
      --no-warnings)
        NO_WARNINGS=1
        shift
        ;;
      -u|--url)
        NB_MANAGEMENT_URL="$2"
        shift 2
        ;;
      -t|--token)
        NB_API_TOKEN="$2"
        shift 2
        ;;
      --config)
        if [[ -z "${2:-}" ]]
        then
          echo_error "--config requires a file path"
          return 1
        fi
        NB_CLI_CONFIG_FILE="$2"
        shift 2
        ;;
      --config=*)
        NB_CLI_CONFIG_FILE="${1#--config=}"
        shift
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
      -F|--field)
        OUTPUT=field
        FIELD="$2"
        shift 2
        ;;
      -I|--id*)
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
      --compact|--truncate)
        COMPACT=1
        shift 1
        ;;
      --columns|--cols)
        local CUSTOM_COLUMNS=1
        mapfile -t JSON_COLUMNS < <(tr ',' '\n' <<< "$2")

        COLUMN_NAMES=() # Reset
        local col col_capitalized
        for col in "${JSON_COLUMNS[@]}"
        do
          col_capitalized="$(awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1' <<< "${col//./ }")"
          COLUMN_NAMES+=("$col_capitalized")
        done
        shift 2
        ;;
      -s|--sort*)
        SORT_BY="$2"
        CUSTOM_SORT=1
        shift 2
        ;;
      -r|--resolve)
        RESOLVE=1
        shift
        ;;
      -R|--no-resolve|--nores*)
        NO_RESOLVE=1
        shift
        ;;
      --retries)
        RETRIES="$2"
        shift 2
        ;;
      --)
        shift
        ARGS+=("$@")
        break
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
    echo_error "Missing item"
    usage >&2
    exit 2
  fi

  if [[ -z "$NB_API_TOKEN" ]]
  then
    echo_error "Missing API token"
    echo_error "Either set NB_API_TOKEN or use the -t option"
    exit 2
  fi

  local API_ITEM="$1"
  shift

  local HELP_ACTION
  if [[ -n "$1" ]] && ! is_nb_id "$1"
  then
    if [[ "$ACTION" == "help" ]]
    then
      HELP_ACTION=1
    fi

    ACTION="$1"
    shift
  fi

  case "$API_ITEM" in
    a|acc*)
      API_OBJECT="account"
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_accounts
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    country*|geo*)
      API_OBJECT="country"
      if [[ -z "$*" ]]
      then
        if [[ -z "$CUSTOM_COLUMNS" ]]
        then
          JSON_COLUMNS=(country_code country_name)
          COLUMN_NAMES=(Code Name)
        fi

        [[ -z "$CUSTOM_SORT" ]] && SORT_BY=country_name
      else
        if [[ -z "$CUSTOM_COLUMNS" ]]
        then
          JSON_COLUMNS=(city_name geoname_id)
          COLUMN_NAMES=(City "Geo ID")
        fi

        # FIXME This does result in öäü etc being sorted after 'z'
        [[ -z "$CUSTOM_SORT" ]] && SORT_BY=city_name
      fi

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_countries
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    d|dns*|ns*|nameser*)
      API_OBJECT="dns"
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_dns
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    e|event*)
      API_OBJECT="event"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(activity initiator_name timestamp)
        COLUMN_NAMES=(Activity Initiator Time)
      fi

      [[ -z "$CUSTOM_SORT" ]] && SORT_BY=timestamp

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_events
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    g|gr*)
      API_OBJECT="group"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(name peers_count peers)
        COLUMN_NAMES=("Name" "Peer count" Peers)
      fi

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_groups
          ;;
        create)
          if [[ -n "$HELP_ACTION" ]]
          then
            usage_create_group
            return 0
          fi
          COMMAND=nb_create_group
          ;;
        del|delete|rm|remove)
          COMMAND=nb_delete_group
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    n|net*)
      API_OBJECT="network"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(name description resources routers routing_peers_count)
        COLUMN_NAMES=("Name" "Description" "Resources" "Routers" "Routing Peers")
      fi

      [[ -z "$CUSTOM_SORT" ]] && SORT_BY=name

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_networks
          ;;
        create)
          if [[ -n "$HELP_ACTION" ]]
          then
            usage_create_network
            return 0
          fi
          COMMAND=nb_create_network
          ;;
        del|delete|rm|remove)
          COMMAND=nb_delete_network
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    p|peer*)
      API_OBJECT="peer"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(hostname ip dns_label connected ssh_enabled version groups)
        COLUMN_NAMES=(Hostname "Netbird IP" "DNS" Connected "SSH" Version Groups)
      fi

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_peers
          ;;
        update)
          COMMAND=nb_update_peer
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    pol*)
      API_OBJECT="policy"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(name description enabled rules)
        COLUMN_NAMES=("Name" "Description" "Enabled" "Rules")
      fi

      [[ -z "$CUSTOM_SORT" ]] && SORT_BY=name

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_policies
          ;;
        create)
          if [[ -n "$HELP_ACTION" ]]
          then
            usage_create_policy
            return 0
          fi
          COMMAND=nb_create_policy
          ;;
        del|delete|rm|remove)
          COMMAND=nb_delete_policy
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    postu*)
      API_OBJECT="posture_check"
      case "$ACTION" in
        list|get)
          COMMAND=nb_list_posture_checks
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    res*)
      API_OBJECT="network_resource"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(name type groups description address)
        COLUMN_NAMES=("Name" "Type" "Groups" "Description" "Address")
      fi

      [[ -z "$CUSTOM_SORT" ]] && SORT_BY=name

      case "$ACTION" in
        list|get)
          JSON_COLUMNS=(network.name "${JSON_COLUMNS[@]}")
          COLUMN_NAMES=(Network "${COLUMN_NAMES[@]}")
          [[ -z "$CUSTOM_SORT" ]] && SORT_BY=network.name
          COMMAND=nb_list_network_resources
          ;;
        create)
          if [[ -n "$HELP_ACTION" ]]
          then
            usage_create_network_resource
            return 0
          fi
          COMMAND=nb_create_network_resource
          ;;
        del|delete|rm|remove)
          COMMAND=nb_delete_network_resource
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    r|ro|route|routes)
      API_OBJECT="route"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(network_id network masquerade metric groups peer_groups)
        COLUMN_NAMES=("Net ID" "Network" "MASQ" "Metric" "Dist Groups" "Peer Groups")
      fi

      [[ -z "$CUSTOM_SORT" ]] && SORT_BY=network_id

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_routes
          ;;
        create)
          if [[ -n "$HELP_ACTION" ]]
          then
            usage_create_route
            return 0
          fi
          COMMAND=nb_create_route
          ;;
        del|delete|rm|remove)
          COMMAND=nb_delete_route
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    router*|routing-peers)
      API_OBJECT="router"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(masquerade metric peer peer_groups)
        COLUMN_NAMES=("MASQ" "Metric" "Peer" "Groups")
      fi

      [[ -z "$CUSTOM_SORT" ]] && SORT_BY=id

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_network_routers
          JSON_COLUMNS=(network.name "${JSON_COLUMNS[@]}")
          COLUMN_NAMES=(Network "${COLUMN_NAMES[@]}")
          [[ -z "$CUSTOM_SORT" ]] && SORT_BY=network.name
          ;;
        create)
          if [[ -n "$HELP_ACTION" ]]
          then
            usage_create_network_router
            return 0
          fi
          COMMAND=nb_create_network_router
          ;;
        del|delete|rm|remove)
          COMMAND=nb_delete_network_router
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    s|setup*)
      API_OBJECT="setup-key"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(name auto_groups state key)
        COLUMN_NAMES=("Name" Groups State Key)
      fi

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_setup_keys
          ;;
        create)
          if [[ -n "$HELP_ACTION" ]]
          then
            usage_create_setup_key
            return 0
          fi
          COMMAND=nb_create_setup_key
          ;;
        update)
          if [[ -n "$HELP_ACTION" ]]
          then
            usage_create_setup_key | sed 's#create#update#g'
            return 0
          fi
          COMMAND=nb_update_setup_key
          ;;
        rev|revoke)
          COMMAND=nb_revoke_setup_key
          ;;
        del|delete)
          COMMAND=nb_delete_setup_key
          ;;
        renew)
          COMMAND=nb_renew_setup_key
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    ssh)
      case "$ACTION" in
        on|enable)
          nb_ssh_enable "$@"
          return "$?"
          ;;
        off|disable)
          nb_ssh_disable "$@"
          return "$?"
          ;;
        *)
          echo_error "Unknown ssh action: $ACTION"
          return 2
          ;;
      esac
      ;;
    t|token*)
      API_OBJECT="token"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(name created_at expiration_date last_used)
        COLUMN_NAMES=(Name "Created At" "Expires" "Last Used")
      fi

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_tokens
          ;;
        create)
          if [[ -n "$HELP_ACTION" ]]
          then
            usage_create_token
            return 0
          fi
          COMMAND=nb_create_token
          ;;
        del|delete|rm|remove)
          COMMAND=nb_delete_token
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    u|user*)
      API_OBJECT="user"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(name role auto_groups)
        COLUMN_NAMES=(Name Role "Groups")
      fi

      case "$ACTION" in
        list|get)
          COMMAND=nb_list_users
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    w|whoami|self|me)
      API_OBJECT="whoami"
      if [[ -z "$CUSTOM_COLUMNS" ]]
      then
        JSON_COLUMNS=(name role auto_groups)
        COLUMN_NAMES=(Name Role "Groups")
      fi

      case "$ACTION" in
        list|get)
          COMMAND=nb_whoami
          ;;
        help)
          usage
          return 0
          ;;
      esac
      ;;
    *)
      echo_error "Unknown object: $API_ITEM"
      return 2
      ;;
  esac

  case "$OUTPUT" in
    pretty)
      RESOLVE=1
      # Skip header and color if output is not a terminal
      if [[ ! -t 1 ]]
      then
        NO_HEADER=1
        NO_COLOR=1
      fi
      ;;
    field)
      if [[ -z "$FIELD" ]]
      then
        echo_error "Output set to field but no field name provided"
        return 2
      fi
      ;;
    plain)
      RESOLVE=1
      NO_COLOR=1
      OUTPUT=pretty
      ;;
  esac

  if [[ -n "$WITH_ID_COL" ]]
  then
    JSON_COLUMNS=(id "${JSON_COLUMNS[@]}")
    COLUMN_NAMES=(ID "${COLUMN_NAMES[@]}")
  fi

  if [[ -z "$COMMAND" ]]
  then
    echo_error "No command provided"
    usage >&2
    return 2
  fi

  echo_debug "\$ $COMMAND ${*@Q}"
  JSON_DATA="$("$COMMAND" "$@")"

  if [[ -z "$JSON_DATA" ]]
  then
    return 1
  elif [[ "$JSON_DATA" == "{}" || "$JSON_DATA" == "[]" ]]
  then
    return 0
  fi

  # Convert JSON_DATA to array if it contains only one object
  if <<<"$JSON_DATA" jq -er '(. | type) == "object"' &>/dev/null
  then
    JSON_DATA=$(jq -s '.' <<< "$JSON_DATA")
  fi

  if [[ -n "$RESOLVE" && -z "$NO_RESOLVE" ]] # negativity wins
  then
    JSON_DATA="$(nb_resolve_lazy "$API_OBJECT" <<< "$JSON_DATA")"
  fi

  case "$OUTPUT" in
    json)
      jq -e "${JQ_ARGS[@]}" <<< "$JSON_DATA"
      ;;
    *)
      if [[ -n "$FIELD" ]]
      then
        <<<"$JSON_DATA" jq -er --arg field "$FIELD" '.[] | .[$field]'
        return "$?"
      fi

      # special post-processing
      case "$COMMAND" in
        nb_list_events)
          if [[ -z "$CUSTOM_COLUMNS" ]]
          then
            JSON_COLUMNS+=(meta_str)
            COLUMN_NAMES+=(Meta)
          fi
          JSON_DATA=$(nb_prettify_events_json <<< "$JSON_DATA")
          ;;
      esac

      pretty_output <<< "$JSON_DATA"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  main "$@"
fi
