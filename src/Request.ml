open Response_code

type 'body t = {
    meth: Method.t;
    host: string;
    client: Async.client;
    headers: Headers.t;
    cookies: Cookies.t;
    http_version: int*int;
    path: string;
    path_components: string list;
    query: (string*string) list;
    body: 'body;
    start_time: float;
    trailer : (Headers.t * Cookies.t) option ref;
    (* updated after ready chunked body *)
  }

let fail_raise = Headers.fail_raise
let log = Log.f

let headers self = self.headers
let cookies self = self.cookies
let host self = self.host
let meth self = self.meth
let path self = self.path
let body self = self.body
let client self = self.client
let start_time self = self.start_time
let trailer self = !(self.trailer)

let query self = self.query
let get_header ?f self h = Headers.get ?f h self.headers
let get_header_int self h = match get_header self h with
  | Some x -> (try Some (int_of_string x) with _ -> None)
  | None -> None
let set_header k v self = {self with headers=Headers.set k v self.headers}
let update_headers f self = {self with headers=f self.headers}
let set_body b self = {self with body=b}

let get_cookie self h =
  try Some (Cookies.get h self.cookies)
  with Not_found -> None

let set_cookie self c =
  { self with cookies = Cookies.add c self.cookies }

let get_cookie_string self h =
  let c = Cookies.get h self.cookies in
  Http_cookie.value c

let get_cookie_int self h =
  int_of_string (get_cookie_string self h)

(** Should we close the connection after this request? *)
let close_after_req (self:_ t) : bool =
  match self.http_version with
  | 1, 1 -> get_header self Headers.Connection = Some"close"
  | 1, 0 -> not (get_header self Headers.Connection = Some"keep-alive")
  | _ -> false

let pp_comp_ out comp =
  Format.fprintf out "[%s]"
    (String.concat ";" @@ List.map (Printf.sprintf "%S") comp)
let pp_query out q =
  Format.fprintf out "[%s]"
    (String.concat ";" @@
       List.map (fun (a,b) -> Printf.sprintf "%S,%S" a b) q)
let pp_ out self : unit =
  Format.fprintf out "{@[meth=%s;@ host=%s;@ headers=[@[%a@]];@ \
                      path=%S;@ body=?;@ path_components=%a;@ query=%a@]}"
    (Method.to_string self.meth) self.host Headers.pp self.headers self.path
    pp_comp_ self.path_components pp_query self.query
let pp out self : unit =
  Format.fprintf out "{@[meth=%s;@ host=%s;@ headers=[@[%a@]];@ path=%S;@ \
                      body=%S;@ path_components=%a;@ query=%a@]}"
    (Method.to_string self.meth) self.host Headers.pp self.headers
    self.path self.body pp_comp_ self.path_components pp_query self.query

(* decode a "chunked" stream into a normal stream *)
let read_stream_chunked_ ~buf ~trailer (bs:Input.t) : Input.t =
  Input.read_chunked ~buf ~trailer
    ~fail:(fun s -> fail_raise ~code:bad_request "%s" s)
    bs

let limit_body_size_ ~max_size (bs:Input.t) : Input.t =
  Input.limit_size_to ~max_size ~close_rec:false bs
    ~too_big:(fun size ->
      (* read too much *)
      fail_raise ~code:content_too_large
        "body size was supposed to be %d, but at least %d bytes received"
        max_size size
    )

let limit_body_size ~max_size (req:Input.t t) : Input.t t =
  { req with body=limit_body_size_ ~max_size req.body }

(* read exactly [size] bytes from the stream *)
let read_exactly ~size (bs:Input.t) : Input.t =
  Input.read_exactly bs ~close_rec:false
    ~size ~too_short:(fun size ->
      fail_raise ~code:bad_request "body is too short by %d bytes" size)

(* parse request, but not body (yet) *)
let parse_req_start ~client ~buf (bs:Input.t)
    : Input.t t option =
  try
    let start_time = Async.register_starttime client in
    let meth = Method.parse bs in
    let _ = Input.exact_char ' ' () bs in
    let path = Input.read_until ~buf ~target:" " bs; Buffer.contents buf in
    let _ = Input.exact_string "HTTP/" () bs in
    let major = Input.int bs in
    let _ = Input.exact_char '.' () bs in
    let minor = Input.int bs in
    let _ = Input.exact_char '\r' () bs in
    let _ = Input.exact_char '\n' () bs in
    if major != 1 || (minor != 0 && minor != 1) then raise Exit;
    log (Req 0) (fun k->k "From %s: %s, path %S" (Util.addr_of_sock client.sock)
                          (Method.to_string meth) path);
    let (headers, cookies) = Headers.parse_ ~buf bs in
    let host =
      match Headers.get Headers.Host headers with
      | None -> fail_raise ~code:bad_request "No 'Host' header in request"
      | Some h -> h
    in
    let path_components, query = Util.split_query path in
    let path_components = Util.split_on_slash path_components in
    let path_components = List.map Util.percent_decode path_components in

    let query =
      match Util.(parse_query query) with
      | Ok l -> l
      | Error e -> fail_raise ~code:bad_request "invalid query: %s" e
    in
    let req = {
        meth; query; host; client; path; path_components;
        headers; cookies; http_version=(major, minor); body=bs; start_time;
        trailer = ref None;
      } in
    Some req
  with
  | End_of_file -> None
  | Headers.Bad_req _ as e -> raise e
  | Exit | Input.FailParse ->
     log (Exc 1) (fun k->k "Invalid request line");
     fail_raise ~code:bad_request "Invalid request line"
  | e -> fail_raise ~code:internal_server_error "exception: %s" (Async.printexn e)

let parse_multipart_ ~bound req =
  let body = req.body in
  let buf = Buffer.create 1024 in
  let buf2 = Buffer.create 1024 in
  let _ = Input.read_line ~buf body in
  let query = ref [] in
  let cont = ref true in
  while !cont do
    let (header, _) = Headers.parse_ ~buf body in
    let cd = match Headers.get Content_Disposition header
      with Some cd -> cd
         | None -> raise Not_found
    in
    let key =
      Scanf.sscanf cd "form-data; name = %S " (* FIXME: filename *)
        String.trim
    in
    let value =
      Input.read_until ~buf:buf2 ~target:bound body;
      let line = Input.read_line ~buf body in
      if String.trim line = "--" then cont := false;
      Buffer.contents buf2
    in
    query := (key, value) :: !query
  done;
  { req with query = List.rev_append !query req.query }

(* parse body, given the headers.
   @param tr_stream a transformation of the input stream. *)
let parse_body_ ~tr_stream ~buf (req:Input.t t) : Input.t t =
  try
    Buffer.clear buf;
    let size =
      match Headers.get_exn Headers.Content_Length req.headers
            |> int_of_string with
      | n -> n (* body of fixed size *)
      | exception Not_found -> 0
      | exception _ -> fail_raise ~code:bad_request "invalid Content-Length"
    in
    let trailer bs =
      req.trailer := Some (Headers.parse_ ~buf bs)
    in
    let is_multipart, bound =
      try
        match Headers.(get Content_Type req.headers)
        with
        | Some ct ->
           Scanf.sscanf ct "multipart/form-data ; boundary = %s "
             (fun b -> (true, "--" ^ b))
        | None -> (false, "")
      with _ -> (false, "")
    in
    let transfer_encoding =
      get_header ~f:String.trim req Headers.Transfer_Encoding
    in
    let req =
      match transfer_encoding, is_multipart
      with
      | None, false ->
         let body = read_exactly ~size @@ tr_stream req.body in
         { req with body }
      | None, true ->
         let req = parse_multipart_ ~bound req in
         let body = Input.of_string "" in
         { req with body }
      | Some "chunked", _ ->
         let bs =
           read_stream_chunked_ ~buf ~trailer @@ tr_stream req.body
                                                           (* body sent by chunks, with a trailer *)
         in
         let body = if size>0 then limit_body_size_ ~max_size:size bs else bs in
         let req = { req with body } in
         if is_multipart then
           parse_multipart_ ~bound req
         else
           req
      | Some s, _ -> fail_raise ~code:not_implemented "cannot handle transfer encoding: %s" s
    in
    req
  with
  | End_of_file -> fail_raise ~code:bad_request "unexpected end of file"
  | Headers.Bad_req _ as e -> raise e
  | e -> fail_raise ~code:internal_server_error "exception: %s" (Async.printexn e)

let parse_body ~buf req : Input.t t =
  parse_body_ ~tr_stream:(fun s->s) ~buf req

let read_body_full ~buf (self:Input.t t) : string t =
  try
    let body = Input.read_all ~buf self.body in
    { self with body }
  with
  | e -> fail_raise ~code:bad_request "failed to read body: %s" (Async.printexn e)

(*$R
  let module Request = Simple_httpd__Request in
  let module Async   = Simple_httpd__Async in
  let module Input   = Simple_httpd__Input in
  let module Output  = Simple_httpd__Output in
  let module Headers = Simple_httpd__Headers in
  Log.set_log_requests 0;
  let q = "GET hello HTTP/1.1\r\nHost: coucou\r\nContent-Length: 11\r\n\r\nsalutationsSOMEJUNK" in
  let str = Input.of_string q in
  let buf = Buffer.create 256 in
  let r = Request.parse_req_start ~buf ~client:Async.fake_client
             str in
  match r with
  | None -> assert_failure "should parse"
  | Some req ->
    let module H = Headers in
    let headers = Request.headers req in
    assert_equal (Some "coucou") (Headers.get Headers.Host headers);
    assert_equal (Some "11") (Headers.get Headers.Content_Length headers);
    assert_equal "hello" (Request.path req);
    let req = Request.parse_body ~buf req
      |> Request.read_body_full ~buf in
    assert_equal ~printer:(fun s->s) "salutations" (Request.body req);
    ()
*)
