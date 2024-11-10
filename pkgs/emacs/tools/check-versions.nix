{
  lib,
  emacsVersion,
  builtinLibraries,
  emptyFile,
  runCommandLocal,
  jq,
}: packageInputs: let
  inherit
    (builtins)
    mapAttrs
    hasAttr
    elem
    length
    match
    head
    substring
    lessThan
    concatLists
    concatStringsSep
    attrNames
    ;

  srcDateString = src: substring 0 8 src.lastModifiedDate;

  inputVersion = isDate: attrs:
    if isDate
    then srcDateString attrs.src
    else if ! attrs ? version
    then null
    # Some packages have a version suffixed with "-pre", and there are
    # packages that depend on the version with the suffix removed. For
    # example, envrc depends on inheritenv 0.1, while the latest version of
    # inheritenv is 0.1-pre at present. In this case, we will consider that
    # envrc depends on a pre-release version of the package, which should work
    # once the version is officially released. Thus, we can strip "-pre"
    # suffix.
    else lib.removeSuffix "-pre" attrs.version;

  compareVersions = isDate: current: required:
    if isDate
    then ! lessThan (lib.toInt current) (lib.toInt required)
    else lib.versionAtLeast current required;

  # Some packages (e.g. magit) contain dates as dependency versions in *-pkg.el.
  dependencyStatus = ename: required:
    removeAttrs
    rec {
      isDateVersion =
        required
        != null
        && length (lib.splitVersion required) == 1
        && match "[0-9]{8}" (head (lib.splitVersion required)) != null;
      inherit required;
      current =
        if ename == "emacs"
        then emacsVersion
        else if hasAttr ename packageInputs
        then inputVersion isDateVersion packageInputs.${ename}
        else if elem ename builtinLibraries
        then "builtin"
        else throw "Package ${ename} is missing from packageInputs";
      satisfied =
        required
        == null
        || current == "builtin"
        || (
          if current == null
          # There are packages that seem to have removed a version header. In
          # that case, there are dependants that have a version requirement,
          # while their dependency actually have no version. It is impossible
          # to compare the versions in this case. I don't know if I can simply
          # ignore this case, so I will display a warning for now.
          then lib.warn "Package ${ename} has no version header" true
          else compareVersions isDateVersion current required
        );
    } ["isDateVersion"];

  filterErrors = lib.filterAttrs (_: {satisfied, ...}: !satisfied);

  status = rec {
    summary = lib.pipe errors [
      (lib.mapAttrsToList (requiredBy:
        lib.mapAttrsToList
        (ename: status:
          {
            inherit ename requiredBy;
          }
          // status)))
      concatLists
      (builtins.groupBy ({ename, ...}: ename))
      (mapAttrs (_ename: statuses: {
        inherit ((head statuses)) current;
        # Showing the source date may be useful, but maybe later.
        #
        # lastModifiedDate =
        #   if hasAttr ename packageInputs
        #   then packageInputs.${ename}.src.lastModifiedDate or null
        #     # unavailable
        #   else null;
        required = lib.pipe (lib.catAttrs "required" statuses) [
          lib.naturalSort
          lib.last
        ];
        details =
          map (status: removeAttrs status ["current" "ename" "satisfied"]) statuses;
      }))
    ];
    errors = lib.pipe packages [
      (mapAttrs (_: filterErrors))
      (lib.filterAttrs (_: attrs: attrs != {}))
    ];
    packages = lib.pipe packageInputs [
      (mapAttrs (_: {packageRequires, ...}:
          mapAttrs dependencyStatus packageRequires))
    ];
  };
in
  if status.errors == {}
  then emptyFile
  else
    runCommandLocal "emacs-deps-error" {
      passthru = status;
      errors = builtins.toJSON status.errors;
      passAsFile = ["errors"];
    } ''
      echo "Warning: The following packages have insufficient dependencies:" >&2
      ${jq}/bin/jq . $errorsPath >&2

      echo >&2 "Error: Some packages require updates: ${
        concatStringsSep " " (attrNames status.summary)
      }"

      exit 1
    ''
