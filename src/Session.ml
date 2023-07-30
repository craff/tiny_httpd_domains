open Response_code

type t = Async.session
type data = Util.data
type 'a key = 'a Util.key

let new_key () = Util.new_key (fun _ -> ())
let new_key_with_cleanup = Util.new_key

module LinkedList = Util.LinkedList

let get_session, delete_session =
  (* table to search session by key *)
  let sessions_tbl = Hashtbl.create 1024 in
  let mutex_tbl = Mutex.create () in
  (* session orderer by expiration data *)
  let sessions_list = LinkedList.create () in
  let mutex_list = Mutex.create () in
  let delete_session sess =
    let session = LinkedList.get sess in
    Mutex.lock mutex_tbl;
    Hashtbl.remove sessions_tbl session.Async.key;
    Mutex.unlock mutex_tbl;
    let fn clients =
      List.iter (fun cl -> Async.set_session cl) clients;
      []
    in
    Util.update_atomic session.clients fn;
    Mutex.lock mutex_list;
    (try LinkedList.remove_cell sess sessions_list;
         Mutex.unlock mutex_list
     with e ->
       Mutex.unlock mutex_list; raise e);
    (*List.iter Async.close session.clients;*)
    Util.cleanup (Atomic.get session.data);
  in
  let refresh session =
    let now = Unix.gettimeofday () in
    Mutex.lock mutex_list;
    try
      LinkedList.move_first session sessions_list;
      (LinkedList.get session).last_refresh <- now;
      while  let l = LinkedList.tail sessions_list in
             let sess = LinkedList.get l in
             LinkedList.is_cell l && now -. sess.last_refresh > sess.life_time do
        let l = LinkedList.tail sessions_list in
        LinkedList.remove_cell l sessions_list;
      done;
      Mutex.unlock mutex_list;
    with e ->
      Mutex.unlock mutex_list;
      raise e
  in
  let get_session ?(session_life_time=3600.0) client key =
    Mutex.lock mutex_tbl;
    try
      match client.Async.session with
      | Some (s : t) ->
         Mutex.unlock mutex_tbl;
         refresh s;
         (s, true)
      | None ->
         let session = match key with
           | None -> None
           | Some key -> Hashtbl.find_opt sessions_tbl key
         in
         match session with
         | Some session ->
            Async.set_session ~session client;
            Mutex.unlock mutex_tbl;
            let sc = LinkedList.get session in
            let fn clients = client :: clients in
            Util.update_atomic sc.clients fn;
            refresh session;
            (session, true)
         | None ->
            Mutex.unlock mutex_tbl;
            let addr = Util.addr_of_sock client.sock in
            let key = Digest.to_hex
                        (Digest.string (addr ^ string_of_int (Random.int 1_000_000_000))) in
            let data = Atomic.make Util.empty in
            let now = Unix.gettimeofday () in
            let session_info =
              Async.({ addr; key; clients= Atomic.make [client]
                       ; data
                       ; life_time = session_life_time
                       ; last_refresh = now })
            in
            Mutex.lock mutex_list;
            let session = LinkedList.add_first session_info sessions_list in
            Mutex.unlock mutex_list;
            Async.set_session ~session client;
            Mutex.lock mutex_tbl;
            Hashtbl.add sessions_tbl key session;
            Mutex.unlock mutex_tbl;
            (session, false)
    with e ->
      Mutex.unlock mutex_tbl; raise e
  in
  (get_session, delete_session)

let get_session_data (sess : Async.session) key =
  let l = Atomic.get (LinkedList.get sess).data in
  Util.search key l

let do_session_data : Async.session -> (data -> 'a * data) -> 'a =
  fun (sess : Async.session) fn ->
    let session = LinkedList.get sess in
    Util.get_update_atomic session.data fn

let set_session_data (sess : Async.session) key x =
  do_session_data sess (fun l -> (), Util.add_replace key x l)

let remove_session_data sess key =
  do_session_data sess (fun l -> (), Util.remove key l)

let mk_cookies (sess : Async.session) filter c =
  let session = LinkedList.get sess in
  let max_age = Int64.of_float session.life_time in
  let c = List.filter_map
            (fun c ->
              let name = Http_cookie.name c in
              if name = "SESSION_KEY" || name = "SESSION_ADDR" then
                None
              else match filter c with
                   | Some x -> Some x
                   | None -> Some (Http_cookie.expire c)) c
  in
  let c = Cookies.create ~name:"SESSION_KEY" ~max_age
            ~same_site:`Strict session.key c in
  let c = Cookies.create ~name:"SESSION_ADDR" ~max_age
            ~same_site:`Strict session.addr c in
  c

let check
      ?(session_life_time=3600.0)
      ?(check=fun _ -> true)
      ?(filter=fun x -> Some x)
      ?(error=(bad_request, [])) req =
  let cookies = Request.cookies req in
  let client = Request.client req in
  let key = Option.map Http_cookie.value
              (Request.get_cookie req "SESSION_KEY")
  in
  let (sess, old) = get_session ~session_life_time client key in
  let session = LinkedList.get sess in
  try
    if not (check sess) then raise Exit;
    let cookies =
      if old then
        begin
          begin
            match (key, Request.get_cookie req "SESSION_ADDR") with
            | (Some key, Some addr) when
                   key = session.key &&
                     Http_cookie.value addr = session.addr -> ()
            | (None, None) when cookies = [] -> ()
            | _ -> raise Exit
            | exception _ -> raise Exit
          end;
          let addr = Util.addr_of_sock client.sock in
          if addr <> session.addr then raise Exit;
          cookies
        end
      else
        Cookies.delete_all cookies
    in
    (mk_cookies sess filter cookies, sess)
  with Exit ->
    delete_session sess;
    let cookies = Cookies.delete_all cookies in
    let (code, headers) = error in
    Response.fail_raise ~headers ~cookies ~code "session ends"

let _check = check

let filter
      ?(session_life_time=3600.0)
      ?(check=fun _ -> true)
      ?(filter=fun x -> Some x)
      ?(error=(bad_request, [])) req =
  let (cookies, _) = _check ~session_life_time ~check ~filter
                       ~error req in
  let gn = Response.update_headers
             (fun h -> Headers.set_cookies cookies h) in
  (req, gn)

exception NoSession

let get_session req =
  let client = Request.client req in
  let key = Option.map Http_cookie.value
              (Request.get_cookie req "SESSION_KEY")
  in
  let (sess, _) = get_session client key in
  sess
