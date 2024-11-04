defmodule AcmeClient.Poller do
  @moduledoc ~S"""
    Orchestrate the steps of processing the cert order.

    From https://datatracker.ietf.org/doc/html/rfc8555

    +-------------------+--------------------------------+--------------+
    | Action            | Request                        | Response     |
    +-------------------+--------------------------------+--------------+
    | Submit order      | POST newOrder                  | 201 -> order |

  The order is created first, synchronously, to make sure that it succeeds.
  Then the Poller process is started to complete the remaining steps.

    | Fetch challenges  | POST-as-GET order's            | 200          |
    |                   | authorization urls             |              |
    |                   |                                |              |
    | Respond to        | POST authorization challenge   | 200          |
    | challenges        | urls                           |              |
    |                   |                                |              |
    | Poll for status   | POST-as-GET order              | 200          |
    |                   |                                |              |
    | Finalize order    | POST order's finalize url      | 200          |
    |                   |                                |              |
    | Poll for status   | POST-as-GET order              | 200          |
    |                   |                                |              |
    | Download          | POST-as-GET order's            | 200          |
    | certificate       | certificate url                |              |
    +-------------------+--------------------------------+--------------+

  Order objects are created in the "pending" state.  Once all of the
  authorizations listed in the order object are in the "valid" state, the order
  transitions to the "ready" state.  The order moves to the "processing" state
  after the client submits a request to the order's "finalize" URL and the CA
  begins the issuance process for the certificate.  Once the certificate is
  issued, the order enters the "valid" state.  If an error occurs at any of
  these stages, the order moves to the "invalid" state.  The order also moves
  to the "invalid" state if it expires or one of its authorizations enters a
  final state other than "valid" ("expired", "revoked", or "deactivated").

  State Transitions for Order Objects:

    pending --------------+
       |                  |
       | All authz        |
       | "valid"          |
       V                  |
     ready ---------------+
       |                  |
       | Receive          |
       | finalize         |
       | request          |
       V                  |
   processing ------------+
       |                  |
       | Certificate      | Error or
       | issued           | Authorization failure
       V                  V
     valid             invalid

  Authorization objects are created in the "pending" state. If one of the
  challenges listed in the authorization transitions to the "valid" state, then
  the authorization also changes to the "valid" state. If the client attempts
  to fulfill a challenge and fails, or if there is an error while the
  authorization is still pending, then the authorization transitions to the
  "invalid" state. Once the authorization is in the "valid" state, it can
  expire ("expired"), be deactivated by the client ("deactivated", see Section
  7.5.2), or revoked by the server ("revoked").

  State Transitions for Authorization Objects:

                   pending --------------------+
                      |                        |
    Challenge failure |                        |
           or         |                        |
          Error       |  Challenge valid       |
            +---------+---------+              |
            |                   |              |
            V                   V              |
         invalid              valid            |
                                |              |
                                |              |
                                |              |
                 +--------------+--------------+
                 |              |              |
                 |              |              |
          Server |       Client |   Time after |
          revoke |   deactivate |    "expires" |
                 V              V              V
              revoked      deactivated      expired

  Challenge objects are created in the "pending" state. They transition to the
  "processing" state when the client responds to the challenge (see Section
  7.5.1) and the server begins attempting to validate that the client has
  completed the challenge. Note that within the "processing" state, the server
  may attempt to validate the challenge multiple times (see Section 8.2).
  Likewise, client requests for retries do not cause a state change.  If
  validation is successful, the challenge moves to the "valid" state; if
  there is an error, the challenge moves to the "invalid" state.

  State Transitions for Challenge Objects:

             pending
                |
                | Receive
                | response
                V
            processing <-+
                |   |    | Server retry or
                |   |    | client retry request
                |   +----+
                |
                |
     Successful  |   Failed
     validation  |   validation
      +---------+---------+
      |                   |
      V                   V
     valid              invalid

  """
  use GenServer, restart: :temporary

  alias AcmeClient.Session

  require Logger

  @rate_limit_times 3
  @poll_interval 60_000

  # alias AcmeClient.Telemetry

  def start_link(args, opts \\ []) do
    # Logger.debug("args: #{inspect(args)}")
    [id | _rest] = args[:identifiers]
    name = {:via, Registry, {AcmeClient.Registry, id}}
    opts = Keyword.put_new(opts, :name, name)
    GenServer.start_link(__MODULE__, args, opts)
  end

  @impl GenServer
  def init(args) do
    Logger.debug("args: #{inspect(args)}")

    url = args[:url]
    poll_interval = args[:poll_interval] || @poll_interval

    cb_mod = args[:cb_mod]
    {:ok, cb_context} = apply(cb_mod, :init, [args])

    validate_ns = args[:validate_ns] || true
    valid_ns = args[:valid_ns] || []

    state = %{
      # parent: args[:parent],
      # Basic wait time between cycles
      poll_interval: poll_interval,
      # AcmeClient session
      session: args[:session],
      # Callback module for project specific functions
      cb_mod: cb_mod,
      cb_context: cb_context,
      # Order URL
      url: url,
      # Order data
      order: args[:order],
      # Order status
      status: :pending,
      challenge_responses: args[:challenge_responses],
      dns_records: false || !validate_ns,
      dns_opts: args[:dns_opts] || [],
      validate_ns: validate_ns,
      valid_ns: valid_ns
    }

    # Put order URL in logger metadata
    Logger.metadata(Keyword.put(Logger.metadata(), :url, url))

    # with {:ok, session} <- AcmeClient.create_session(),
    #      {:ok, session, order} <- AcmeClient.get_object(session, url)
    # do
    #   data = %{data | session: session, order: order}
    #   state = order_status_to_state(order)
    #
    #   {:ok, state, data, [timeout]}
    # else
    #   err ->
    #     # Assume it's a transient error
    #     Logger.error("#{url}: error #{inspect(err)}")
    #
    #     {:ok, :pending, data, [timeout]}
    # end

    # Spread out load from multiple polling processes
    Process.send_after(self(), :timeout, :rand.uniform(poll_interval))

    {:ok, state}
  end

  # @impl true
  # def terminate(reason, state) do
  #   Logger.debug("reason: #{reason}")
  #   Process.send(state.parent, :done, [])
  # end

  # def handle_continue(:spread, state) do
  #   # Spread out load from multiple polling processes
  #   Process.send_after(self(), :timeout, :rand.uniform(poll_interval))
  #   {:noreply, state}
  # end

  # Convert order status to atom state
  defp order_status_to_state(%{"status" => "pending"}), do: :pending
  defp order_status_to_state(%{"status" => "ready"}), do: :ready
  defp order_status_to_state(%{"status" => "processing"}), do: :processing
  defp order_status_to_state(%{"status" => "valid"}), do: :valid
  defp order_status_to_state(%{"status" => "invalid"}), do: :invalid

  # Order objects are created in the "pending" state. Once all of the
  # authorizations listed in the order object are in the "valid" state, the
  # order transitions to the "ready" state.

  @impl true
  def handle_info(:timeout, %{session: nil} = state) do
    # start_time = Telemetry.start(:create_session, metadata)
    case AcmeClient.create_session() do
      {:ok, session} ->
        Logger.debug("Created ACME session")
        {:noreply, %{state | session: session}, 0}

      {:error, session, :throttled} ->
        Logger.debug("HTTP rate limited nonce throttled")
        {:noreply, %{state | session: session}, @rate_limit_times * state.poll_interval}

      {:error, %Tesla.Env{status: 429}} ->
        Logger.warning("HTTP rate limited nonce")
        {:noreply, state, @rate_limit_times * state.poll_interval}

      {:error, reason} ->
        Logger.error("Error creating ACME session: #{inspect(reason)}")
        {:noreply, state, state.poll_interval}
    end
  end

  def handle_info(:timeout, %{status: :pending, challenge_responses: nil} = state) do
    Logger.info("#{state.status}, creating challenge responses")

    case get_order_status(state) do
      {:ok, session, order} ->
        set_logger_metadata(order)
        key = session.account_key

        case AcmeClient.get_urls(session, order["authorizations"]) do
          {:ok, session, authorizations} ->
            Logger.debug("authorizations: #{inspect(authorizations)}")

            responses =
              authorizations
              |> Enum.map(fn {_url, auth} -> create_challenge_responses(auth, key) end)
              |> List.flatten()
              |> merge_challenge_responses()
              |> publish_challenge_responses(state.cb_mod)

            Logger.debug("responses: #{inspect(responses)}")

            {:noreply, %{state | challenge_responses: responses, session: session}, 0}

          {:error, :throttled} ->
            Logger.warning("HTTP rate limited throttled")
            {:noreply, %{state | session: session}, @rate_limit_times * state.poll_interval}

          {:error, %{status: 429, body: %{"detail" => "Rate limit for '/acme' reached"}}} ->
            Logger.warning("HTTP rate limited /acme")
            {:noreply, %{state | session: nil}, @rate_limit_times * state.poll_interval}

          {:error, reason} ->
            Logger.error("Error getting authorizations: #{inspect(reason)}")
            {:noreply, %{state | session: nil}, state.poll_interval}
        end

      other ->
        other
    end
  end

  def handle_info(
        :timeout,
        %{status: :pending = status, challenge_responses: challenge_responses, dns_records: false} =
          state
      ) do
    Logger.info("#{status}, polling until DNS ready")

    results =
      for {_domain, responses} <- challenge_responses, response <- responses do
        %{"domain" => domain, "response" => response_code} = response

        case state.validate_ns do
          true ->
            case validate_ns(domain, state.valid_ns, 2) do
              {_domain, :valid} ->
                host = AcmeClient.dns_challenge_name(domain)
                txt_records = AcmeClient.dns_txt_records(host)

                if response_code in txt_records do
                  Logger.debug("DNS found #{host} #{response_code}")
                  :ok
                else
                  Logger.debug("DNS not found #{host} #{response_code}")
                  :transient
                end

              {_domain, :invalid} ->
                :permanent

              {_domain, :missing} ->
                :permanent
            end

          false ->
            :ok
        end
      end

    Logger.debug("results: #{inspect(results)}")

    cond do
      Enum.any?(results, fn result -> result == :permanent end) ->
        Logger.warning("Stopping due to invalid NS")
        {:stop, :normal, state}

      Enum.all?(results, fn result -> result == :ok end) ->
        Logger.info("All DNS found")
        # The session is generally invalid by the time the DNS records are
        # available, so trigger a refresh rather than getting an error
        {:noreply, %{state | dns_records: true, session: nil}, 0}

      true ->
        {:noreply, state, state.poll_interval}

        # if apply(state.cb_mod, :valid_domain?, [domain, state.cb_context]) do
        # else
        #   Logger.warning("Stopping invalid #{state.url}: domain is invalid")
        #  {:stop, :normal, state}
        # end
    end
  end

  def handle_info(
        :timeout,
        %{status: :pending, challenge_responses: challenge_responses, dns_records: true} = state
      ) do
    Logger.info("#{state.status}, processing challenges")

    # Poll until status is "ready"
    case get_order_status(state) do
      {:ok, session, order} ->
        set_logger_metadata(order)

        # Logger.debug("challenge_responses: #{inspect(challenge_responses)}")
        session =
          for {_domain, responses} <- challenge_responses,
              response <- responses,
              reduce: session do
            nil ->
              nil

            session ->
              %{"domain" => domain, "url" => ready_url} = response

              case AcmeClient.poke_url(session, ready_url) do
                {:ok, session, _poke_result} ->
                  Logger.info("#{domain}: Challenge ready #{ready_url}")
                  session

                {:error, session, :throttled = reason} ->
                  Logger.warning("#{domain} Error poking #{ready_url}: #{reason}")
                  session

                {:error, session, reason} ->
                  Logger.error("#{domain} Error poking #{ready_url}: #{inspect(reason)}")
                  session

                {:error, reason} ->
                  Logger.error("#{domain} Error poking #{ready_url}: #{inspect(reason)}")
                  nil
              end
          end

        {:noreply, %{state | session: session, order: order}, state.poll_interval * 2}

      other ->
        other
    end
  end

  def handle_info(:timeout, %{status: :ready = status} = state) do
    Logger.info("#{status}, finalizing order")

    case get_order_status(state) do
      {:ok, session, order} ->
        set_logger_metadata(order)

        finalize_url = order["finalize"]
        domain = get_domain(order["identifiers"])

        with {:get_csr, {:ok, csr_pem}} <- {:get_csr, apply(state.cb_mod, :get_csr, [domain])},
             {:from_pem, {:ok, csr}} <- {:from_pem, X509.CSR.from_pem(csr_pem)},
             {:to_der, csr_der} <- {:to_der, X509.CSR.to_der(csr)},
             {:json_encode, {:ok, json}} <-
               {:json_encode, Jason.encode(%{csr: Base.url_encode64(csr_der)})} do
          case AcmeClient.post_as_get(session, finalize_url, json) do
            {:ok, session, %{status: 200}} ->
              Logger.debug("CSR: #{json}")
              Logger.info("Finalized order #{finalize_url}")
              {:noreply, %{state | session: session, order: order}, 0}

            {:error, session, :throttled} ->
              Logger.warning("HTTP rate limited throttled")

              {:noreply, %{state | session: session, order: order},
               @rate_limit_times * state.poll_interval}

            {:error, session,
             %{status: 429, body: %{"detail" => "Rate limit for '/acme' reached"}}} ->
              Logger.warning("HTTP rate limited /acme")

              {:noreply, %{state | session: session, order: order},
               @rate_limit_times * state.poll_interval}

            {:error, session, reason} ->
              Logger.error("Error finalizing: #{inspect(reason)}")
              {:noreply, %{state | session: session, order: order}, state.poll_interval}

              {:error,
               %{
                 status: 403,
                 body: %{
                   "type" => "urn:ietf:params:acme:error:orderNotReady"
                   # "detail" => "Order's status (\"valid\") is not acceptable for finalization"
                 }
               }}

              Logger.warning("Already finalized")
              {:noreply, %{state | session: nil, order: order}, 0}

              # %{
              #   "detail" =>
              #     "Error finalizing order :: Rechecking CAA for \"*.example.com\" and 1 more identifiers failed. Refer to sub-problems for more information",
              #   "status" => 403,
              #   "subproblems" => [
              #     %{
              #       "detail" =>
              #         "Error finalizing order :: While processing CAA for *.example.com: DNS problem: query timed out looking up CAA for example.com",
              #       "identifier" => %{"type" => "dns", "value" => "*.example.com"},
              #       "status" => 403,
              #       "type" => "urn:ietf:params:acme:error:caa"
              #     },
              #     %{
              #       "detail" =>
              #       "Error finalizing order :: While processing CAA for example.com: DNS problem: query timed out looking up CAA for example.com",
              #       "identifier" => %{"type" => "dns", "value" => "example.com"},
              #       "status" => 403,
              #       "type" => "urn:ietf:params:acme:error:caa"}
              #   ],
              #   "type" => "urn:ietf:params:acme:error:caa"
              # }
              {:error, reason}
              Logger.error("Error finalizing: #{inspect(reason)}")
              {:noreply, %{state | session: nil, order: order}, state.poll_interval}
          end
        else
          err ->
            Logger.error("Error finalizing: #{inspect(err)}")
            apply(state.cb_mod, :handle_finalization_error, [order, err])

            {:noreply, %{state | session: nil, order: order}, state.poll_interval}
        end

      other ->
        other
    end
  end

  def handle_info(:timeout, %{status: :processing = status} = state) do
    Logger.info("#{status}, polling until status = 'valid'")

    case get_order_status(state) do
      {:ok, session, order} ->
        set_logger_metadata(order)

        {:noreply, %{state | session: session, order: order}, state.poll_interval}

      other ->
        other
    end
  end

  def handle_info(:timeout, %{status: :valid} = state) do
    Logger.info("#{state.status}, downloading certificate")

    case get_order_status(state) do
      {:ok, session, order} ->
        set_logger_metadata(order)

        case AcmeClient.get_object(session, order["certificate"]) do
          {:ok, session, certificate} ->
            Logger.info("certificate: #{certificate}")

            case apply(state.cb_mod, :process_certificate, [order, certificate]) do
              :ok ->
                apply(state.cb_mod, :ack_order, [order])

                Logger.warning("Stopping valid #{state.url}")
                {:stop, :normal, state}

              err ->
                Logger.error("Error running process_certificate: #{inspect(err)}")
                {:noreply, %{state | session: session, order: order}, state.poll_interval}
            end

          {:error, session, :throttled} ->
            Logger.warning("HTTP rate limited throttled")

            {:noreply, %{state | session: session, order: order},
             @rate_limit_times * state.poll_interval}

          {:error, session, %{status: 429, body: %{"detail" => "Rate limit for '/acme' reached"}}} ->
            Logger.warning("HTTP rate limited /acme")

            {:noreply, %{state | session: session, order: order},
             @rate_limit_times * state.poll_interval}

          err ->
            Logger.error("Error reading certificate: #{inspect(err)}")
            {:noreply, %{state | session: nil, order: order}, state.poll_interval}
        end

      other ->
        other
    end
  end

  def handle_info(:timeout, %{status: :invalid = status} = state) do
    Logger.warning("#{status}, invalid order")
    %{url: url} = state

    case get_order_status(state) do
      {:ok, _session, order} ->
        set_logger_metadata(order)

        Logger.debug("order: #{inspect(order)}")

        apply(state.cb_mod, :invalid_order, [order])

        Logger.warning("Stopping invalid #{url}")

        {:stop, :normal, state}

      other ->
        other
    end
  end

  def handle_info(message, state) do
    Logger.warning("Unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  def process_authorization(%{"status" => "pending"} = authorization, {session, results}) do
    %{"identifier" => %{"type" => "dns", "value" => domain}} = authorization
    Logger.info("authorization: #{inspect(authorization)}")

    process_challenge =
      fn
        %{"status" => "valid", "type" => "dns-01"} = challenge, {session, challenges} ->
          %{"token" => token} = challenge
          response = AcmeClient.dns_challenge_response(token, session.account_key)
          challenge = Map.put(challenge, "response", response)
          Logger.info("challenge: #{inspect(challenge)}")

          host = AcmeClient.dns_challenge_name(domain)
          txt_records = AcmeClient.dns_txt_records(host)

          if response in txt_records do
            Logger.info("#{domain}: DNS found for #{host} #{response}")
            {session, [challenge | challenges]}
          else
            Logger.info("#{domain}: DNS not found for #{host} #{response}")
            {session, [challenge | challenges]}
          end

        %{"status" => "invalid", "type" => "dns-01"}, acc ->
          Logger.warning("#{domain} Invalid challenge")
          acc

        %{"status" => "processing", "type" => "dns-01"}, acc ->
          acc

        %{"status" => "pending", "type" => "dns-01"} = challenge, {session, challenges} ->
          %{"token" => token, "url" => url} = challenge
          response = AcmeClient.dns_challenge_response(token, session.account_key)
          challenge = Map.put(challenge, "response", response)
          Logger.info("challenge: #{inspect(challenge)}")

          host = AcmeClient.dns_challenge_name(domain)
          txt_records = AcmeClient.dns_txt_records(host)

          if response in txt_records do
            Logger.info("#{domain}: DNS challenge response found for #{host} #{response}")

            case AcmeClient.poke_url(session, url) do
              {:ok, session, poke_result} ->
                Logger.info("#{domain}: poked #{url}: #{inspect(poke_result)}")
                {session, [challenge | challenges]}

              {:error, session, reason} ->
                Logger.error("#{domain}: Error poking #{url}: #{inspect(reason)}")
                {session, [challenge | challenges]}
            end
          else
            Logger.info("#{domain}: DNS challenge response not found for #{host} #{response}")
            {session, [challenge | challenges]}
          end

        _, acc ->
          acc
      end

    {session, challenges} =
      Enum.reduce(authorization["challenges"], {session, []}, process_challenge)

    authorization = Map.put(authorization, "challenges", challenges)
    {session, [authorization | results]}
  end

  def process_authorization(%{"status" => "valid"}, acc) do
    Logger.info("status: valid")
    acc
  end

  def process_authorization(%{"status" => status}, acc) do
    Logger.warning("Authorization status #{status}")
    acc
  end

  # def challenge_response(%{"status" => "valid", "type" => "dns-01"}, acc), do: acc
  # def challenge_response(%{"status" => "processing", "type" => "dns-01"}, acc), do: acc
  # def challenge_response(%{"status" => "pending", "type" => "dns-01"}, acc) do
  #   %{"token" => token, "url" => url} = challenge

  #   response = AcmeClient.dns_challenge_response(token, session.account_key)
  #   challenge = Map.put(challenge, "response", response)

  #   Logger.info("challenge: #{inspect(challenge)}")

  #   host = AcmeClient.dns_challenge_name(domain)
  #   txt_records = AcmeClient.dns_txt_records(host)

  #   if response in txt_records do
  #     case AcmeClient.poke_url(session, url) do
  #       {:ok, session, poke_result} ->
  #         Logger.info("#{domain}: poked #{url}: #{inspect(poke_result)}")
  #         {session, [challenge | challenges]}
  #       {:error, session, reason} ->
  #         Logger.error("#{domain}: Error poking #{url}: #{inspect(reason)}")
  #         {session, [challenge | challenges]}
  #     end
  #   else
  #     Logger.info("#{domain}: DNS challenge response not found for #{host}")
  #     {session, [challenge | challenges]}
  #   end
  # end

  def process_challenge(c, {session, results}) do
    {session, [c | results]}
  end

  @spec create_challenge_responses(map(), JOSE.JWK.t()) :: list(map())
  def create_challenge_responses(authorization, key) do
    %{"identifier" => %{"type" => "dns", "value" => domain}} = authorization

    for challenge <- authorization["challenges"],
        # challenge["status"] in ["pending", "valid"],
        challenge["type"] == "dns-01" do
      response = AcmeClient.dns_challenge_response(challenge["token"], key)

      challenge
      |> Map.take(["type", "token", "url"])
      |> Map.merge(%{"domain" => domain, "response" => response})
      |> Map.merge(Map.take(authorization, ["wildcard"]))
    end
  end

  @doc "If challenge response works, tell server"
  @spec respond_to_challenge(map(), Session.t() | nil) :: Session.t() | nil
  def respond_to_challenge(_challenge, nil), do: nil

  def respond_to_challenge(challenge, session) do
    %{"response" => response, "domain" => domain, "url" => url} = challenge
    host = AcmeClient.dns_challenge_name(domain)
    txt_records = AcmeClient.dns_txt_records(host)

    if response in txt_records do
      case AcmeClient.poke_url(session, url) do
        {:ok, session, poke_result} ->
          Logger.info("#{domain}: poked #{url}: #{inspect(poke_result)}")
          session

        {:error, session, reason} ->
          Logger.error("#{domain}: Error poking #{url}: #{inspect(reason)}")
          session

        {:error, reason} ->
          Logger.error("#{domain}: Error poking #{url}: #{inspect(reason)}")
          nil
      end
    else
      Logger.info("#{domain}: DNS challenge response not found for #{host}")
      session
    end
  end

  @doc "Merge responses with same domain"
  @spec merge_challenge_responses([map()]) :: map()
  def merge_challenge_responses(responses) do
    for %{"domain" => domain} = response <- responses, reduce: %{} do
      acc -> Map.update(acc, domain, [response], fn cur -> [response | cur] end)
    end
  end

  @spec publish_challenge_responses(map(), module() | nil) :: map()
  def publish_challenge_responses(responses, nil), do: responses

  def publish_challenge_responses(responses, cb_mod) do
    apply(cb_mod, :publish_challenge_responses, [responses])
    responses
  end

  def get_domain(identifiers) do
    [domain | _rest] =
      for %{"type" => type, "value" => value} <- identifiers,
          type == "dns",
          not String.starts_with?(value, "*.") do
        value
      end

    domain
  end

  def get_id(identifiers), do: get_domain(identifiers)

  def set_logger_metadata(order) do
    metadata = Logger.metadata()

    if not Keyword.has_key?(metadata, :id) do
      id = get_id(order["identifiers"])
      Logger.metadata(Keyword.put(metadata, :id, id))
    end
  end

  @doc "Get order, handling errors and state transition."
  def get_order_status(state) do
    %{url: url, session: session, status: status} = state

    case AcmeClient.get_object(session, url) do
      {:ok, session, order} ->
        set_logger_metadata(order)

        case order_status_to_state(order) do
          ^status ->
            {:ok, session, order}

          new_status ->
            Logger.info("Transition to #{inspect(new_status)}")
            {:noreply, %{state | status: new_status, order: order, session: session}, 0}
        end

      {:error, session, :throttled} ->
        Logger.warning("HTTP rate limited throttled")
        {:noreply, %{state | session: session}, @rate_limit_times * state.poll_interval}

      {:error, session, %{status: 429, body: %{"detail" => "Rate limit for '/acme' reached"}}} ->
        Logger.warning("HTTP rate limited /acme")
        {:noreply, %{state | session: session}, @rate_limit_times * state.poll_interval}

      {:error, session,
       %{status: 404, body: %{"type" => "urn:ietf:params:acme:error:malformed"} = body}} ->
        Logger.warning("Order not found for #{url} #{inspect(body["detail"])}")
        {:noreply, %{state | session: session}, state.poll_interval}

      err ->
        Logger.error("Error getting order: #{inspect(err)}")
        {:noreply, %{state | session: nil}, state.poll_interval}
    end
  end

  @spec validate_ns(binary(), list(binary), non_neg_integer()) ::
          {domain :: binary(), :valid | :invalid | :missing}
  def validate_ns(domain, valid_ns, tries)

  def validate_ns(domain, _valid_ns, 0) do
    {domain, :missing}
  end

  def validate_ns(domain, valid_ns, tries) do
    case :inet_res.lookup(to_charlist(domain), :in, :ns) do
      [] ->
        # Logger.info("#{domain} nameservers missing")
        validate_ns(domain, valid_ns, tries - 1)

      values ->
        ns = Enum.map(values, &to_string/1)

        if Enum.all?(ns, &(&1 in valid_ns)) do
          # Logger.debug("#{domain} nameservers valid: #{inspect(nameservers)}")
          {domain, :valid}
        else
          # Logger.warning("#{domain} nameservers invalid: #{inspect(nameservers)}")
          {domain, :invalid}
        end
    end
  end
end
