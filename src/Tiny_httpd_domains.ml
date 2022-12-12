open Effect
open Effect.Deep
open Domain

type status = {
    nb_availables : int Atomic.t;
    nb_connections : int Atomic.t array
  }

type client = {
    mutable counter : int;
    mutable granularity : int;
    sock : Unix.file_descr;
    status : status;
  }

type _ Effect.t +=
   | Read  : client * Bytes.t * int * int -> int Effect.t
   | Write : client * Bytes.t * int * int -> int Effect.t

type action = Read|Write
type pending =
  {client:client; action:action; buf:Bytes.t; offset:int; len: int;
   cont : (int,unit) continuation; mutable count:int}

exception Closed

let read  c s o l =
  c.counter <- c.counter + 1;
  if c.counter mod c.granularity = 0 &&
       (Atomic.get c.status.nb_connections.((Domain.self () :> int)) > 1 ||
          Atomic.get c.status.nb_availables <= 0) then
    perform (Read (c,s,o,l))
  else
    try
      let n = Unix.read c.sock s o l in
      if n = 0 then raise Closed; n
    with Unix.(Unix_error((EAGAIN|EWOULDBLOCK),_,_)) ->
      perform (Read (c,s,o,l))

let write c s o l =
  c.counter <- c.counter + 1;
  if c.counter mod c.granularity = 0 &&
       (Atomic.get c.status.nb_connections.((Domain.self () :> int)) > 1 ||
          Atomic.get c.status.nb_availables <= 0) then
     perform (Write(c,s,o,l))
  else
    try
      let n = Unix.single_write c.sock s o l in
      if n = 0 then raise Closed; n
    with Unix.(Unix_error((EAGAIN|EWOULDBLOCK),_,_)) ->
      perform (Write (c,s,o,l))

let is_ipv6 addr = String.contains addr ':'

let connect addr port maxc =
  ignore (Unix.sigprocmask Unix.SIG_BLOCK [Sys.sigpipe] : _ list);
  let sock =
    Unix.socket
      (if is_ipv6 addr then Unix.PF_INET6 else Unix.PF_INET)
      Unix.SOCK_STREAM
      0
  in
  Unix.set_nonblock sock;
  Unix.setsockopt_optint sock Unix.SO_LINGER None;
  Unix.setsockopt sock Unix.SO_REUSEADDR true;
  Unix.setsockopt sock Unix.SO_REUSEPORT true;
  let inet_addr = Unix.inet_addr_of_string addr in
  Unix.bind sock (Unix.ADDR_INET (inet_addr, port));
  Unix.listen sock maxc;
  sock

type pollResult =
  | Timeout
  | Accept
  | Action of pending

let loop id st addr port maxc granularity handler () =
  let listen_sock = connect addr port maxc in
  let pendings = Hashtbl.create 32 in
  let events = Poll.create () in
  let _ = Poll.(set events listen_sock Event.read) in
  let n = ref 0 in
  let find s = try Hashtbl.find pendings s with _ -> assert false in
  let poll timeout =
    let _ = Poll.(set events listen_sock Event.read) in
    let do_decr =
      if Hashtbl.length pendings = 0 then (Atomic.incr st.nb_availables; true)
      else false
    in
    match Poll.wait events timeout with
    | `Timeout ->
       if do_decr then Atomic.decr st.nb_availables;
       Poll.clear events;
       Timeout
    | `Ok ->
       if do_decr then Atomic.decr st.nb_availables;
       let best = ref None in
       let f sock _evt =
         if sock == listen_sock then raise Exit;
         let {count = n';_} as p = find sock in
         match !best with
         | None -> best := Some p
         | Some{count = n;_} -> if n' < n then best:=Some p
       in
       try
         Poll.iter_ready events ~f;
         Poll.clear events;
         match !best with
         | None -> assert false
         | Some p -> Action p
       with
       | Exit -> Poll.clear events; Accept
  in
  let rec do_job () =
    let last_sock = ref None in
    (*Printf.eprintf "poll %d %d\n%!" id (Hashtbl.length pendings);*)
    (try
      match poll (Poll.Timeout.After 10_000_000L) with
      | Timeout -> Domain.cpu_relax (); ()
      | Accept ->
         Printf.eprintf "accept connection from %d\n%!" id;
         Atomic.incr st.nb_connections.(id);
         let sock, _ = Unix.accept listen_sock in
         Unix.set_nonblock sock;
         let client = { sock; counter = 0; granularity; status = st } in
         last_sock:=Some sock;
         handler client
      | Action { action; client; buf; offset; len; cont; _ } ->
         Poll.(set events client.sock Event.none);
         Hashtbl.remove pendings client.sock;
         let n =
           try
             match action with
             | Read  -> Unix.read client.sock buf offset len
             | Write -> Unix.single_write client.sock buf offset len
           with Unix.(Unix_error((EAGAIN|EWOULDBLOCK),_,_)) -> assert false
         in
         if n = 0 then raise Closed;
         last_sock := Some client.sock;
         continue cont n;
    with e ->
      Printf.eprintf "exn: %s\n%!" (Printexc.to_string e));
    begin
      match !last_sock with
      | None -> ()
      | Some s ->
         Atomic.incr st.nb_connections.(id);
         try Unix.close s with _ -> ()
    end;
    do_job ()
  and loop () =
    try_with do_job ()
    { effc = (fun (type c) (eff: c Effect.t) ->
        match eff with
        | Read (client,buf,offset,len) ->
           Some (fun (cont : (c,_) continuation) ->
               incr n;
               Poll.(set events client.sock Event.read);
               Hashtbl.add pendings client.sock
                 {client;action=Read;buf;offset;len;cont;count = !n};
               loop ())
        | Write(client,buf,offset,len) ->
           Some (fun (cont : (c,_) continuation) ->
               incr n;
               (* TODO: does not seem to work if we wait only for write ????*)
               Poll.(set events client.sock Event.read_write);
               Hashtbl.add pendings client.sock
                 {client;action=Write;buf;offset;len;cont;count = !n};
               loop ())
        | _ -> None
    )}
  in loop ()

let run nb addr port maxc granularity handler =
  let status = {
      nb_availables = Atomic.make 0;
      nb_connections = Array.init nb (fun _ -> Atomic.make 0)
    }
  in
  let fn id = spawn (loop id status addr port maxc granularity handler) in
  let r = Array.init (nb-1) fn in
  let _ = fn (nb-1) in
  r
