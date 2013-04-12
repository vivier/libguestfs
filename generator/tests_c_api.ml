(* libguestfs
 * Copyright (C) 2009-2013 Red Hat Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 *)

(* Please read generator/README first. *)

open Printf

open Types
open Utils
open Pr
open Docstrings
open Optgroups
open Actions
open Structs

(* Generate the tests. *)
let rec generate_tests () =
  generate_header CStyle GPLv2plus;

  pr "\
#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <assert.h>

#include <pcre.h>

#include \"guestfs.h\"
#include \"guestfs-internal-frontend.h\"

static guestfs_h *g;

/* FIXME: nearly identical code appears in fish.c */
static void
print_strings (char *const *argv)
{
  size_t argc;

  for (argc = 0; argv[argc] != NULL; ++argc)
    printf (\"\\t%%s\\n\", argv[argc]);
}

static void
incr (guestfs_h *g, void *iv)
{
  int *i = (int *) iv;
  (*i)++;
}

static int compare_lists (char **, char **, int (*) (const char *, const char *));
static int compare_devices (const char *, const char *);

/* Compare 'ret' to the string list that follows. */
static int
is_string_list (char **ret, size_t n, ...)
{
  CLEANUP_FREE /* sic */ char **expected = malloc ((n+1) * sizeof (char *));
  size_t i;
  va_list args;

  va_start (args, n);
  for (i = 0; i < n; ++i)
    expected[i] = va_arg (args, char *);
  expected[n] = NULL;
  va_end (args);
  return compare_lists (ret, expected, strcmp);
}

/* Compare 'ret' to the device list that follows. */
static int
is_device_list (char **ret, size_t n, ...)
{
  CLEANUP_FREE /* sic */ char **expected = malloc ((n+1) * sizeof (char *));
  size_t i;
  va_list args;

  va_start (args, n);
  for (i = 0; i < n; ++i)
    expected[i] = va_arg (args, char *);
  expected[n] = NULL;
  va_end (args);
  return compare_lists (ret, expected, compare_devices);
}

static int
compare_lists (char **ret, char **expected,
               int (*compare) (const char *, const char *))
{
  size_t i;

  for (i = 0; ret[i] != NULL; ++i) {
    if (!expected[i]) {
      fprintf (stderr, \"test failed: returned list is too long\\n\");
      goto fail;
    }
    if (compare (ret[i], expected[i]) != 0) {
      fprintf (stderr, \"test failed: elements differ at position %%zu\\n\", i);
      goto fail;
    }
  }
  if (expected[i]) {
    fprintf (stderr, \"test failed: returned list is too short\\n\");
    goto fail;
  }

  return 1; /* test expecting true for OK */

 fail:
  fprintf (stderr, \"returned list was:\\n\");
  print_strings (ret);
  fprintf (stderr, \"expected list was:\\n\");
  print_strings (expected);
  return 0; /* test expecting false for failure */
}

/* Compare two device names, ignoring hd/sd/vd */
static int
compare_devices (const char *dev1, const char *dev2)
{
  CLEANUP_FREE char *copy1 = NULL, *copy2 = NULL;

  assert (dev1 && dev2);
  if (strlen (dev1) < 6 || strlen (dev2) < 6)
    return -1;

  copy1 = strdup (dev1);
  copy2 = strdup (dev2);
  copy1[5] = 'h';
  copy2[5] = 'h';

  return strcmp (copy1, copy2);
}

/* Compare returned buffer with expected buffer.  Note the buffers have
 * a length and may contain ASCII NUL characters.
 */
static int
compare_buffers (const char *b1, size_t s1, const char *b2, size_t s2)
{
  if (s1 != s2)
    return s1 - s2;
  return memcmp (b1, b2, s1);
}

/* Get md5sum of the named file. */
static void
md5sum (const char *filename, char *result)
{
  char cmd[256];
  snprintf (cmd, sizeof cmd, \"md5sum %%s\", filename);
  FILE *pp = popen (cmd, \"r\");
  if (pp == NULL) {
    perror (cmd);
    exit (EXIT_FAILURE);
  }
  if (fread (result, 1, 32, pp) != 32) {
    perror (\"md5sum: fread\");
    exit (EXIT_FAILURE);
  }
  if (pclose (pp) != 0) {
    perror (\"pclose\");
    exit (EXIT_FAILURE);
  }
  result[32] = '\\0';
}

/* Compare MD5 has to expected hash of a file. */
static int
check_file_md5 (const char *ret, const char *filename)
{
  char expected[33];

  md5sum (filename, expected);
  if (STRNEQ (ret, expected)) {
    fprintf (stderr, \"test failed: MD5 returned (%%s) does not match MD5 of file %%s (%%s)\\n\",
             ret, filename, expected);
    return -1;
  }

  return 0;
}

/* Return the value for a key in a hashtable.
 * Note: the return value is part of the hash and should not be freed.
 */
static const char *
get_key (char **hash, const char *key)
{
  size_t i;

  for (i = 0; hash[i] != NULL; i += 2) {
    if (STREQ (hash[i], key))
      return hash[i+1];
  }

  return NULL; /* key not found */
}

/* Compare hash key's value to expected value. */
static int
check_hash (char **ret, const char *key, const char *expected)
{
  const char *value = get_key (ret, key);

  if (STRNEQ (value, expected)) {
    fprintf (stderr, \"test failed: hash key %%s = \\\"%%s\\\" is not expected value \\\"%%s\\\"\\n\",
             key, value, expected);
    return -1;
  }

  return 0;
}

/* Match string with a PCRE regular expression. */
static int
match_re (const char *str, const char *pattern)
{
  const char *err;
  int offset;
  pcre *re;
  size_t len = strlen (str);
  int vec[30], r;

  re = pcre_compile (pattern, 0, &err, &offset, NULL);
  if (re == NULL) {
    fprintf (stderr, \"tests: cannot compile regular expression '%%s': %%s\\n\",
             pattern, err);
    exit (EXIT_FAILURE);
  }
  r = pcre_exec (re, NULL, str, len, 0, 0, vec, sizeof vec / sizeof vec[0]);
  pcre_free (re);

  return r != PCRE_ERROR_NOMATCH;
}

static void
next_test (guestfs_h *g, size_t test_num, size_t nr_tests,
           const char *test_name)
{
  if (guestfs_get_verbose (g))
    printf (\"-------------------------------------------------------------------------------\\n\");
  printf (\"%%3zu/%%3zu %%s\\n\", test_num, nr_tests, test_name);
}

static void
skipped (const char *test_name, const char *fs, ...)
{
  va_list args;
  CLEANUP_FREE char *reason = NULL;
  int len;

  va_start (args, fs);
  len = vasprintf (&reason, fs, args);
  va_end (args);
  assert (len >= 0);

  printf (\"        %%s skipped (reason: %%s)\\n\",
          test_name, reason);
}

";

  (* Generate a list of commands which are not tested anywhere. *)
  pr "static void\n";
  pr "no_test_warnings (void)\n";
  pr "{\n";
  pr "  size_t i;\n";
  pr "  const char *no_tests[] = {\n";

  let hash : (string, bool) Hashtbl.t = Hashtbl.create 13 in
  List.iter (
    fun { tests = tests } ->
      let tests = filter_map (
        function
        | (_, (Always|IfAvailable _), test) -> Some test
        | (_, Disabled, _) -> None
      ) tests in
      let seq = List.concat (List.map seq_of_test tests) in
      let cmds_tested = List.map List.hd seq in
      List.iter (fun cmd -> Hashtbl.replace hash cmd true) cmds_tested
  ) all_functions;

  List.iter (
    fun { name = name } ->
      if not (Hashtbl.mem hash name) then
        pr "    \"%s\",\n" name
  ) all_functions_sorted;

  pr "    NULL\n";
  pr "  };\n";
  pr "\n";
  pr "  for (i = 0; no_tests[i] != NULL; ++i)\n";
  pr "    fprintf (stderr, \"warning: \\\"guestfs_%%s\\\" has no tests\\n\",\n";
  pr "             no_tests[i]);\n";
  pr "}\n";
  pr "\n";

  (* Generate the actual tests.  Note that we generate the tests
   * in reverse order, deliberately, so that (in general) the
   * newest tests run first.  This makes it quicker and easier to
   * debug them.
   *)
  let test_names =
    List.map (
      fun { name = name; optional = optional; tests = tests } ->
        mapi (generate_one_test name optional) tests
    ) (List.rev all_functions) in
  let test_names = List.concat test_names in
  let nr_tests = List.length test_names in

  pr "\
int
main (int argc, char *argv[])
{
  const char *filename;
  int fd;
  const size_t nr_tests = %d;
  size_t test_num = 0;
  size_t nr_failed = 0;

  setbuf (stdout, NULL);

  no_test_warnings ();

  g = guestfs_create ();
  if (g == NULL) {
    printf (\"FAIL: guestfs_create\\n\");
    exit (EXIT_FAILURE);
  }

  filename = \"test1.img\";
  fd = open (filename, O_WRONLY|O_CREAT|O_NOCTTY|O_TRUNC|O_CLOEXEC, 0666);
  if (fd == -1) {
    perror (filename);
    exit (EXIT_FAILURE);
  }
  if (ftruncate (fd, %d) == -1) {
    perror (\"ftruncate\");
    close (fd);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (close (fd) == -1) {
    perror (filename);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (guestfs_add_drive (g, filename) == -1) {
    printf (\"FAIL: guestfs_add_drive %%s\\n\", filename);
    exit (EXIT_FAILURE);
  }

  filename = \"test2.img\";
  fd = open (filename, O_WRONLY|O_CREAT|O_NOCTTY|O_TRUNC|O_CLOEXEC, 0666);
  if (fd == -1) {
    perror (filename);
    exit (EXIT_FAILURE);
  }
  if (ftruncate (fd, %d) == -1) {
    perror (\"ftruncate\");
    close (fd);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (close (fd) == -1) {
    perror (filename);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (guestfs_add_drive (g, filename) == -1) {
    printf (\"FAIL: guestfs_add_drive %%s\\n\", filename);
    exit (EXIT_FAILURE);
  }

  filename = \"test3.img\";
  fd = open (filename, O_WRONLY|O_CREAT|O_NOCTTY|O_TRUNC|O_CLOEXEC, 0666);
  if (fd == -1) {
    perror (filename);
    exit (EXIT_FAILURE);
  }
  if (ftruncate (fd, %d) == -1) {
    perror (\"ftruncate\");
    close (fd);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (close (fd) == -1) {
    perror (filename);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (guestfs_add_drive (g, filename) == -1) {
    printf (\"FAIL: guestfs_add_drive %%s\\n\", filename);
    exit (EXIT_FAILURE);
  }

  if (guestfs_add_drive_ro (g, \"../data/test.iso\") == -1) {
    printf (\"FAIL: guestfs_add_drive_ro ../data/test.iso\\n\");
    exit (EXIT_FAILURE);
  }

  /* Set a timeout in case qemu hangs during launch (RHBZ#505329). */
  alarm (600);

  if (guestfs_launch (g) == -1) {
    printf (\"FAIL: guestfs_launch\\n\");
    exit (EXIT_FAILURE);
  }

  /* Cancel previous alarm. */
  alarm (0);

  /* Create ext2 filesystem on /dev/sdb1 partition. */
  if (guestfs_part_disk (g, \"/dev/sdb\", \"mbr\") == -1) {
    printf (\"FAIL: guestfs_part_disk\\n\");
    exit (EXIT_FAILURE);
  }
  if (guestfs_mkfs (g, \"ext2\", \"/dev/sdb1\") == -1) {
    printf (\"FAIL: guestfs_mkfs (/dev/sdb1)\\n\");
    exit (EXIT_FAILURE);
  }

" nr_tests (500 * 1024 * 1024) (50 * 1024 * 1024) (10 * 1024 * 1024);

  iteri (
    fun i test_name ->
      pr "  test_num++;\n";
      pr "  next_test (g, test_num, nr_tests, \"%s\");\n" test_name;
      pr "  if (%s () == -1) {\n" test_name;
      pr "    printf (\"FAIL: %%s\\n\", \"%s\");\n" test_name;
      pr "    nr_failed++;\n";
      pr "  }\n";
  ) test_names;
  pr "\n";

  pr "  /* Check close callback is called. */
  int close_sentinel = 1;
  guestfs_set_close_callback (g, incr, &close_sentinel);

  guestfs_close (g);

  if (close_sentinel != 2) {
    fprintf (stderr, \"FAIL: close callback was not called\\n\");
    exit (EXIT_FAILURE);
  }

  unlink (\"test1.img\");
  unlink (\"test2.img\");
  unlink (\"test3.img\");

";

  pr "  if (nr_failed > 0) {\n";
  pr "    printf (\"***** %%zu / %%zu tests FAILED *****\\n\", nr_failed, nr_tests);\n";
  pr "    exit (EXIT_FAILURE);\n";
  pr "  }\n";
  pr "\n";

  pr "  exit (EXIT_SUCCESS);\n";
  pr "}\n"

and generate_one_test name optional i (init, prereq, test) =
  let test_name = sprintf "test_%s_%d" name i in

  pr "\
static int
%s_skip (void)
{
  const char *str;

  str = getenv (\"TEST_ONLY\");
  if (str)
    return strstr (str, \"%s\") == NULL;
  str = getenv (\"SKIP_%s\");
  if (str && STREQ (str, \"1\")) return 1;
  str = getenv (\"SKIP_TEST_%s\");
  if (str && STREQ (str, \"1\")) return 1;
  return 0;
}

" test_name name (String.uppercase test_name) (String.uppercase name);

  pr "\
static int
%s (void)
{
  if (%s_skip ()) {
    skipped (\"%s\", \"environment variable set\");
    return 0;
  }

" test_name test_name test_name;

  (* Optional functions should only be tested if the relevant
   * support is available in the daemon.
   *)
  let group_test group =
    let sym = gensym "features" in
    pr "  const char *%s[] = { \"%s\", NULL };\n" sym group;
    pr "  if (!guestfs_feature_available (g, (char **) %s)) {\n" sym;
    pr "    skipped (\"%s\", \"group %%s not available in daemon\",\n"
      test_name;
    pr "             %s[0]);\n" sym;
    pr "    return 0;\n";
    pr "  }\n";
    pr "\n"
  in

  (match optional with
  | Some group -> group_test group
  | None -> ()
  );

  (match prereq with
   | Disabled ->
     pr "  skipped (\"%s\", \"test disabled in generator\");\n" test_name
   | IfAvailable group ->
     group_test group;
     generate_one_test_body name i test_name init test;
   | Always ->
     generate_one_test_body name i test_name init test
  );

  pr "  return 0;\n";
  pr "}\n";
  pr "\n";
  test_name

and generate_one_test_body name i test_name init test =
  (match init with
   | InitNone (* XXX at some point, InitNone and InitEmpty became
               * folded together as the same thing.  Really we should
               * make InitNone do nothing at all, but the tests may
               * need to be checked to make sure this is OK.
               *)
   | InitEmpty ->
       pr "  /* InitNone|InitEmpty for %s */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"]]
   | InitPartition ->
       pr "  /* InitPartition for %s: create /dev/sda1 */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["part_disk"; "/dev/sda"; "mbr"]]
   | InitGPT ->
       pr "  /* InitGPT for %s: create /dev/sda1 */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["part_disk"; "/dev/sda"; "gpt"]]
   | InitBasicFS ->
       pr "  /* InitBasicFS for %s: create ext2 on /dev/sda1 */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["part_disk"; "/dev/sda"; "mbr"];
          ["mkfs"; "ext2"; "/dev/sda1"; ""; "NOARG"; ""; ""];
          ["mount"; "/dev/sda1"; "/"]]
   | InitBasicFSonLVM ->
       pr "  /* InitBasicFSonLVM for %s: create ext2 on /dev/VG/LV */\n"
         test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["part_disk"; "/dev/sda"; "mbr"];
          ["pvcreate"; "/dev/sda1"];
          ["vgcreate"; "VG"; "/dev/sda1"];
          ["lvcreate"; "LV"; "VG"; "8"];
          ["mkfs"; "ext2"; "/dev/VG/LV"; ""; "NOARG"; ""; ""];
          ["mount"; "/dev/VG/LV"; "/"]]
   | InitISOFS ->
       pr "  /* InitISOFS for %s */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["mount_ro"; "/dev/sdd"; "/"]]
   | InitScratchFS ->
       pr "  /* InitScratchFS for %s */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["mount"; "/dev/sdb1"; "/"]]
  );

  pr "\n";

  let get_seq_last = function
    | [] ->
        failwithf "%s: you cannot use [] (empty list) when expecting a command"
          test_name
    | seq ->
        let seq = List.rev seq in
        List.rev (List.tl seq), List.hd seq
  in

  match test with
  | TestRun seq ->
    pr "  /* TestRun for %s (%d) */\n" name i;
    List.iter (generate_test_command_call test_name) seq

  | TestResult (seq, expr) ->
    pr "  /* TestResult for %s (%d) */\n" name i;
    let n = List.length seq in
    iteri (
      fun i cmd ->
        let ret = if i = n-1 then "ret" else sprintf "ret%d" (n-i-1) in
        generate_test_command_call ~ret test_name cmd
    ) seq;
    pr "  if (! (%s)) {\n" expr;
    pr "    fprintf (stderr, \"%%s: test failed: expression false: %%s\\n\",\n";
    pr "             \"%s\", \"%s\");\n" test_name (c_quote expr);
    pr "    if (!guestfs_get_trace (g))\n";
    pr "      fprintf (stderr, \"Set LIBGUESTFS_TRACE=1 to see values returned from API calls.\\n\");\n";
    pr "    return -1;\n";
    pr "  }\n"

  | TestResultString (seq, expected) ->
    pr "  /* TestResultString for %s (%d) */\n" name i;
    let seq, last = get_seq_last seq in
    List.iter (generate_test_command_call test_name) seq;
    generate_test_command_call test_name ~ret:"ret" last;
    pr "  if (! STREQ (ret, \"%s\")) {\n" (c_quote expected);
    pr "    fprintf (stderr, \"%%s: test failed: expected last command %%s to return \\\"%%s\\\" but it returned \\\"%%s\\\"\\n\",\n";
    pr "             \"%s\", \"%s\", ret, \"%s\");\n"
      test_name (List.hd last) (c_quote expected);
    pr "    return -1;\n";
    pr "  }\n"

  | TestResultDevice (seq, expected) ->
    pr "  /* TestResultDevice for %s (%d) */\n" name i;
    let seq, last = get_seq_last seq in
    List.iter (generate_test_command_call test_name) seq;
    generate_test_command_call test_name ~ret:"ret" last;
    pr "  if (compare_devices (ret, \"%s\") != 0) {\n" (c_quote expected);
    pr "    fprintf (stderr, \"%%s: test failed: expected last command %%s to return \\\"%%s\\\" but it returned \\\"%%s\\\"\\n\",\n";
    pr "             \"%s\", \"%s\", ret, \"%s\");\n"
      test_name (List.hd last) (c_quote expected);
    pr "    return -1;\n";
    pr "  }\n"

  | TestResultTrue seq ->
    pr "  /* TestResultTrue for %s (%d) */\n" name i;
    let seq, last = get_seq_last seq in
    List.iter (generate_test_command_call test_name) seq;
    generate_test_command_call test_name ~ret:"ret" last;
    pr "  if (!ret) {\n";
    pr "    fprintf (stderr, \"%%s: test failed: expected last command %%s to return 'true' but it returned 'false'\\n\",\n";
    pr "             \"%s\", \"%s\");\n" test_name (List.hd last);
    pr "    return -1;\n";
    pr "  }\n"

  | TestResultFalse seq ->
    pr "  /* TestResultFalse for %s (%d) */\n" name i;
    let seq, last = get_seq_last seq in
    List.iter (generate_test_command_call test_name) seq;
    generate_test_command_call test_name ~ret:"ret" last;
    pr "  if (ret) {\n";
    pr "    fprintf (stderr, \"%%s: test failed: expected last command %%s to return 'false' but it returned 'true'\\n\",\n";
    pr "             \"%s\", \"%s\");\n" test_name (List.hd last);
    pr "    return -1;\n";
    pr "  }\n"

  | TestLastFail seq ->
    pr "  /* TestLastFail for %s (%d) */\n" name i;
    let seq, last = get_seq_last seq in
    List.iter (generate_test_command_call test_name) seq;
    generate_test_command_call test_name ~expect_error:true last

(* Generate the code to run a command, leaving the result in the C
 * variable named 'ret'.  If you expect to get an error then you should
 * set expect_error:true.
 *)
and generate_test_command_call ?(expect_error = false) ?test ?ret test_name cmd=
  let ret = match ret with Some ret -> ret | None -> gensym "ret" in

  let name, args =
    match cmd with [] -> assert false | name :: args -> name, args in

  (* Look up the function. *)
  let f =
    try List.find (fun { name = n } -> n = name) all_functions
    with Not_found ->
      failwithf "%s: in test, command %s was not found" test_name name in

  (* Look up the arguments and return type. *)
  let style_ret, style_args, style_optargs = f.style in

  (* Match up the arguments strings and argument types. *)
  let args, optargs =
    let rec loop argts args =
      match argts, args with
      | (t::ts), (s::ss) ->
        let args, rest = loop ts ss in
        ((t, s) :: args), rest
      | [], ss -> [], ss
      | ts, [] ->
        failwithf "%s: in test, too few args given to function %s"
          test_name name
    in
    let args, optargs = loop style_args args in
    let optargs, rest = loop style_optargs optargs in
    if rest <> [] then
      failwithf "%s: in test, too many args given to function %s"
        test_name name;
    args, optargs in

  (* Generate a new symbol for each arg, and one for optargs. *)
  let args = List.map (fun (arg, value) -> arg, value, gensym "arg") args in
  let optargs_sym = gensym "optargs" in

  List.iter (
    function
    | OptString _, "NULL", _ -> ()
    | Pathname _, arg, sym
    | Device _, arg, sym
    | Mountable _, arg, sym
    | Dev_or_Path _, arg, sym
    | Mountable_or_Path _, arg, sym
    | String _, arg, sym
    | OptString _, arg, sym
    | Key _, arg, sym ->
      pr "  const char *%s = \"%s\";\n" sym (c_quote arg);
    | BufferIn _, arg, sym ->
      pr "  const char *%s = \"%s\";\n" sym (c_quote arg);
      pr "  size_t %s_size = %d;\n" sym (String.length arg)
    | Int _, _, _
    | Int64 _, _, _
    | Bool _, _, _
    | FileIn _, _, _
    | FileOut _, _, _ -> ()
    | StringList _, "", sym
    | DeviceList _, "", sym ->
      pr "  const char *const %s[1] = { NULL };\n" sym
    | StringList _, arg, sym
    | DeviceList _, arg, sym ->
      let strs = string_split " " arg in
      iteri (
        fun i str ->
          pr "  const char *%s_%d = \"%s\";\n" sym i (c_quote str);
      ) strs;
      pr "  const char *const %s[] = {\n" sym;
      iteri (
        fun i _ -> pr "    %s_%d,\n" sym i
      ) strs;
      pr "    NULL\n";
      pr "  };\n";
    | Pointer _, _, _ ->
      (* Difficult to make these pointers in order to run a test. *)
      assert false
  ) args;

  if optargs <> [] then (
    pr "  struct %s %s;\n" f.c_function optargs_sym;
    let _, bitmask = List.fold_left (
      fun (shift, bitmask) optarg ->
        let is_set =
          match optarg with
          | OBool n, "" -> false
          | OBool n, "true" ->
            pr "  %s.%s = 1;\n" optargs_sym n; true
          | OBool n, "false" ->
            pr "  %s.%s = 0;\n" optargs_sym n; true
          | OBool n, arg ->
            failwithf "boolean optional arg '%s' should be empty string or \"true\" or \"false\"" n
          | OInt n, "" -> false
          | OInt n, i ->
            let i =
              try int_of_string i
              with Failure _ -> failwithf "integer optional arg '%s' should be empty string or number" n in
            pr "  %s.%s = %d;\n" optargs_sym n i; true
          | OInt64 n, "" -> false
          | OInt64 n, i ->
            let i =
              try Int64.of_string i
              with Failure _ -> failwithf "int64 optional arg '%s' should be empty string or number" n in
            pr "  %s.%s = %Ld;\n" optargs_sym n i; true
          | OString n, "NOARG" -> false
          | OString n, arg ->
            pr "  %s.%s = \"%s\";\n" optargs_sym n (c_quote arg); true
          | OStringList n, "NOARG" -> false
          | OStringList n, "" ->
            pr "  const char *const %s[1] = { NULL };\n" n; true
          | OStringList n, arg ->
            let strs = string_split " " arg in
            iteri (
              fun i str ->
                pr "  const char *%s_%d = \"%s\";\n" n i (c_quote str);
            ) strs;
            pr "  const char *const %s[] = {\n" n;
            iteri (
              fun i _ -> pr "    %s_%d,\n" n i
            ) strs;
            pr "    NULL\n";
            pr "  };\n"; true in
        let bit = if is_set then Int64.shift_left 1L shift else 0L in
        let bitmask = Int64.logor bitmask bit in
        let shift = shift + 1 in
        (shift, bitmask)
    ) (0, 0L) optargs in
    pr "  %s.bitmask = UINT64_C(0x%Lx);\n" optargs_sym bitmask;
  );

  (match style_ret with
  | RErr | RInt _ | RBool _ -> pr "  int %s;\n" ret
  | RInt64 _ -> pr "  int64_t %s;\n" ret
  | RConstString _ | RConstOptString _ ->
    pr "  const char *%s;\n" ret
  | RString _ ->
    pr "  CLEANUP_FREE char *%s;\n" ret
  | RStringList _ | RHashtable _ ->
    pr "  CLEANUP_FREE_STRING_LIST char **%s;\n" ret;
  | RStruct (_, typ) ->
    pr "  CLEANUP_FREE_%s struct guestfs_%s *%s;\n"
      (String.uppercase typ) typ ret
  | RStructList (_, typ) ->
    pr "  CLEANUP_FREE_%s_LIST struct guestfs_%s_list *%s;\n"
      (String.uppercase typ) typ ret
  | RBufferOut _ ->
    pr "  CLEANUP_FREE char *%s;\n" ret;
    pr "  size_t size;\n"
  );

  if expect_error then
    pr "  guestfs_push_error_handler (g, NULL, NULL);\n";
  pr "  %s = %s (g" ret f.c_function;

  (* Generate the parameters. *)
  List.iter (
    function
    | OptString _, "NULL", _ -> pr ", NULL"
    | Pathname _, _, sym
    | Device _, _, sym
    | Mountable _, _, sym
    | Dev_or_Path _, _, sym
    | Mountable_or_Path _, _, sym
    | String _, _, sym
    | OptString _, _, sym
    | Key _, _, sym -> pr ", %s" sym
    | BufferIn _, _, sym -> pr ", %s, %s_size" sym sym
    | FileIn _, arg, _
    | FileOut _, arg, _ -> pr ", \"%s\"" (c_quote arg)
    | StringList _, _, sym | DeviceList _, _, sym -> pr ", (char **) %s" sym
    | Int _, arg, _ ->
      let i =
        try int_of_string arg
        with Failure "int_of_string" ->
          failwithf "%s: expecting an int, but got '%s'" test_name arg in
      pr ", %d" i
    | Int64 _, arg, _ ->
      let i =
        try Int64.of_string arg
        with Failure "int_of_string" ->
          failwithf "%s: expecting an int64, but got '%s'" test_name arg in
      pr ", %Ld" i
    | Bool _, arg, _ ->
      let b = bool_of_string arg in pr ", %d" (if b then 1 else 0)
    | Pointer _, _, _ -> assert false
  ) args;

  (match style_ret with
  | RBufferOut _ -> pr ", &size"
  | _ -> ()
  );

  if optargs <> [] then
    pr ", &%s" optargs_sym;

  pr ");\n";

  if expect_error then
    pr "  guestfs_pop_error_handler (g);\n";

  (match errcode_of_ret style_ret, expect_error with
  | `CannotReturnError, _ -> ()
  | `ErrorIsMinusOne, false ->
    pr "  if (%s == -1)\n" ret;
    pr "    return -1;\n";
  | `ErrorIsMinusOne, true ->
    pr "  if (%s != -1)\n" ret;
    pr "    return -1;\n";
  | `ErrorIsNULL, false ->
    pr "  if (%s == NULL)\n" ret;
    pr "      return -1;\n";
  | `ErrorIsNULL, true ->
    pr "  if (%s != NULL)\n" ret;
    pr "    return -1;\n";
  );

  (* Insert the test code. *)
  (match test with
  | None -> ()
  | Some f -> f ret
  )

and gensym prefix =
  sprintf "_%s%d" prefix (unique ())
