defmodule WorkbenchWeb.OrderLive.Index do
  use WorkbenchWeb, :live_view
  import WorkbenchWeb.ViewHelpers.NodeHelper, only: [assign_node: 2]
  import WorkbenchWeb.ViewHelpers.PaginationHelper, only: [assign_pagination: 2]
  import WorkbenchWeb.ViewHelpers.SearchQueryHelper, only: [assign_search_query: 2]

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(Tai.PubSub, "order_updated:*")

    socket =
      socket
      |> assign(:new_follow_orders_count, 0)
      |> assign(:query, nil)
      |> assign(:last_order_updated, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:follow, Map.get(params, "follow") != "false")
      |> assign_node(params)
      |> assign_pagination(params)
      |> assign_search_query(params)
      |> assign_search()

    {:noreply, socket}
  end

  @impl true
  def handle_event("node-selected", params, socket) do
    socket_with_node = assign_node(socket, params)

    socket =
      socket_with_node
      |> assign_search()
      |> push_patch(
        to:
          Routes.order_path(socket_with_node, :index, %{
            node: socket_with_node.assigns.node,
            query: socket_with_node.assigns.query
          })
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", params, socket) do
    socket =
      socket
      |> cancel_search_timer()
      |> assign_search_query(params)
      |> send_search_after(200)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle-follow", _params, socket) do
    follow = !socket.assigns.follow

    socket_with_follow =
      socket
      |> assign(:follow, follow)

    if follow do
      socket =
        socket_with_follow
        |> assign_search()
        |> push_patch(to: Routes.order_path(socket_with_follow, :index))

      {:noreply, socket}
    else
      {:noreply, socket_with_follow}
    end
  end

  @impl true
  def handle_info(:search, socket) do
    socket =
      socket
      |> assign(:search_timer, nil)
      |> assign_search()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_placeholder_orders, socket) do
    orders = socket.assigns.orders
    search_node = String.to_atom(socket.assigns.node)
    loaded_new_orders = orders
                        |> Enum.filter(& &1.venue == nil)
                        |> Enum.map(& &1.client_id)
                        |> Tai.Commander.get_new_orders_by_client_ids(node: search_node)
                        |> Map.new(fn o -> {o.client_id, o} end)

    loaded_orders = orders
                    |> Enum.map(fn o ->
                      if o.venue == nil do
                        Map.fetch!(loaded_new_orders, o.client_id)
                      else
                        o
                      end
                    end)

    socket =
      socket
      |> assign(:search_timer, nil)
      |> assign(:new_follow_orders_count, 0)
      |> assign(:orders, loaded_orders)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:clear_last_order_updated, socket) do
    socket =
      socket
      |> assign(:last_order_updated, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:order_updated, client_id, transition}, socket) do
    socket =
      socket
      |> assign(:last_order_updated, client_id)
      |> cancel_search_timer()
      |> send_clear_last_order_updated_after(5000)
      |> update_or_search_orders(client_id, transition)

    {:noreply, socket}
  end

  defp cancel_search_timer(socket) do
    search_timer = socket.assigns[:search_timer]
    if search_timer do
      Process.cancel_timer(search_timer)
    end

    socket
    |> assign(:search_timer, nil)
  end

  defp update_or_search_orders(socket, client_id, nil) do
    # DEV NOTE:
    # This is an optimization to reduce load on the DB. When we're following
    # newly created orders and there was no search query, we can create a
    # placeholder row with the minimal information that we have to immediately
    # indicate in the UI that a new order was created.
    #
    # We then debounce a full search when based on two conditions:
    # 1. There are N new orders displayed that haven't been loaded
    # 2. T milliseconds have elapsed without the placeholder orders being loaded
    cond do
      socket.assigns.follow && socket.assigns.query == nil ->
        orders = socket.assigns.orders
        orders_count = socket.assigns.orders_count + 1
        new_order = %Tai.NewOrders.Order{client_id: client_id, status: :enqueued}

        updated_orders =
          if length(orders) >= socket.assigns.page_size do
            [new_order]
          else
            orders ++ [new_order]
          end

        new_follow_orders_count = socket.assigns.new_follow_orders_count + 1
        send_load_placeholder_after_ms = if new_follow_orders_count >= 10, do: 0, else: 200

        socket
        |> assign(:new_follow_orders_count, new_follow_orders_count)
        |> assign(:orders_count, orders_count)
        |> assign_pages()
        |> assign(:orders, updated_orders)
        |> send_load_placeholder_orders_after(send_load_placeholder_after_ms)

      socket.assigns.follow ->
        socket
        |> send_search_after(200)

      true ->
        socket
    end
  end

  defp update_or_search_orders(socket, client_id, transition) do
    orders = socket.assigns.orders
    visible_updated_order = Enum.find(orders, &(&1.client_id == client_id))

    # DEV NOTE:
    # This is an optimization to reduce load on the DB. When the updated order
    # is visible in the current page the transition contains all of the required
    # attributes that have been updated. We can just apply them in memory so that
    # we don't need to read from the DB again. When the updated order is not
    # visible in the current page then we don't need to do anything.
    if visible_updated_order do
      %transition_mod{} = transition
      attrs = transition |> transition_mod.attrs() |> Map.new()
      new_status = transition_mod.status(visible_updated_order.status)
      updated_attrs = Map.put(attrs, :status, new_status)

      updated_orders =
        Enum.map(orders, fn o ->
          if o.client_id == client_id do
            Map.merge(o, updated_attrs)
          else
            o
          end
        end)

      socket
      |> assign(:orders, updated_orders)
    else
      socket
    end
  end

  defp send_search_after(socket, after_ms) do
    search_timer = Process.send_after(self(), :search, after_ms)

    socket
    |> assign(:search_timer, search_timer)
  end

  defp send_load_placeholder_orders_after(socket, after_ms) do
    search_timer = Process.send_after(self(), :load_placeholder_orders, after_ms)

    socket
    |> assign(:search_timer, search_timer)
  end

  defp assign_search(socket) do
    query = socket.assigns.query
    search_node = String.to_atom(socket.assigns.node)
    orders_count = Tai.Commander.new_orders_count(query, node: search_node)

    socket_with_assigned_pages =
      socket
      |> assign(:new_follow_orders_count, 0)
      |> assign(:orders_count, orders_count)
      |> assign_pages()

    orders =
      Tai.Commander.new_orders(query,
        page: socket_with_assigned_pages.assigns.current_page,
        page_size: socket_with_assigned_pages.assigns.page_size,
        node: search_node
      )

    socket_with_assigned_pages
    |> assign(:orders, orders)
  end

  defp assign_pages(socket) do
    last_page = max(ceil(socket.assigns.orders_count / socket.assigns.page_size), 1)
    first_page = 1
    assigned_page = if socket.assigns.follow, do: last_page, else: socket.assigns.current_page
    current_page = if assigned_page > last_page, do: first_page, else: assigned_page

    if current_page != assigned_page do
      socket
      |> put_flash(
        :warn,
        "Page parameter=#{assigned_page} is > than the last available page=#{last_page}. The orders table is using the first page=#{
          first_page
        } instead."
      )
    else
      socket
    end
    |> assign(:current_page, current_page)
    |> assign(:last_page, last_page)
  end

  defp send_clear_last_order_updated_after(socket, after_ms) do
    timer = Process.send_after(self(), :clear_last_order_updated, after_ms)

    socket
    |> assign(:clear_last_order_updated_timer, timer)
  end

  defp to(socket, page, current_page, _follow) when page < current_page do
    Routes.order_path(socket, :index, page: page, follow: false)
  end

  defp to(socket, page, _current_page, follow) do
    Routes.order_path(socket, :index, page: page, follow: follow)
  end

  defp render_ping(follow) do
    animate_color_class = unless follow, do: "bg-gray-400"
    relative_color_class = unless follow, do: "bg-gray-500"

    assigns = [
      animate: follow,
      animate_color_class: animate_color_class,
      relative_color_class: relative_color_class
    ]

    ~E"""
    <%= render Stylish.Ping, "ping.html", assigns %>
    """
  end
end
