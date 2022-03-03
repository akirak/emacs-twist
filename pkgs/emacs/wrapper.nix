{ lib
, runCommandLocal
, makeWrapper
, buildEnv
, emacs
, lndir
, texinfo
, elispInputs
, executablePackages
, extraOutputsToInstall
}:
let
  inherit (builtins) length;

  nativeComp = emacs.nativeComp or false;

  # Use a symlink farm for specifying subdirectory names inside site-lisp.
  packageEnv = buildEnv {
    name = "elisp-packages";
    paths = elispInputs;
    pathsToLink = [
      "/share/info"
    ] ++ lib.optional nativeComp "/share/emacs/native-lisp";
    inherit extraOutputsToInstall;
    buildInputs = [
      texinfo
    ];
    postBuild = ''
      if [[ -w $out/share/info ]]
      then
        shopt -s nullglob
        for i in $out/share/info/*.info $out/share/info/*.info.gz; do
          install-info $i $out/share/info/dir
        done
      fi
    '';
  };

  selfInfo = builtins.path {
    name = "emacs-twist.info";
    path = ../../doc/emacs-twist.info;
  };

  wrap = open: end: body: open + body + end;

  lispList = strings:
    wrap "'(" ")"
      (lib.concatMapStringsSep " " (wrap "\"" "\"") strings);
in
runCommandLocal "emacs"
{
  buildInputs = [ lndir texinfo ];
  propagatedBuildInputs = [ emacs packageEnv ] ++ executablePackages;
  nativeBuildInputs = [ makeWrapper ];
  # Useful for use with flake-utils.lib.mkApp
  passthru.exePath = "/bin/emacs";

  passAsFile = [ "subdirs" "siteStartExtra" ];

  nativeLoadPath =
    "${packageEnv}/share/emacs/native-lisp/:${emacs}/share/emacs/native-lisp/:";

  subdirs = ''
    (setq load-path (append ${
      lispList (map (path: "${path}/share/emacs/site-lisp/") elispInputs)
    } load-path))
  '';

  siteStartExtra = ''
    (when init-file-user
      ${lib.concatMapStrings (pkg: ''
          (load "${pkg}/share/emacs/site-lisp/${pkg.ename}-autoloads.el" t t)
      '') elispInputs
    })
  '';
}
  ''
    for dir in bin share/applications share/icons
    do
      mkdir -p $out/$dir
      lndir -silent ${emacs}/$dir $out/$dir
    done

    siteLisp=$out/share/emacs/site-lisp
    mkdir -p $siteLisp
    if [[ -e $subdirsPath ]]
    then
      install -m 444 $subdirsPath $siteLisp/subdirs.el
    else
      echo -n "$subdirs" > $siteLisp/subdirs.el
    fi

    # Append autoloads to the site-start.el provided by nixpkgs
    origSiteStart="${emacs}/share/emacs/site-lisp/site-start.el"
    if [[ -f "$origSiteStart" ]]
    then
      install -m 644 "$origSiteStart" $siteLisp/site-start.el
    else
      touch $siteLisp/site-start.el
    fi
    if [[ -e $siteStartExtraPath ]]
    then
      cat $siteStartExtraPath >> $siteLisp/site-start.el
    else
      echo -n "$siteStartExtra" >> $siteLisp/site-start.el
    fi

    cd $siteLisp
    ${emacs}/bin/emacs --batch -f batch-byte-compile site-start.el
    ${lib.optionalString nativeComp ''
      nativeLisp=$out/share/emacs/native-lisp
      emacs --batch \
        --eval "(push \"$nativeLisp/\" native-comp-eln-load-path)" \
        --eval "(setq native-compile-target-directory \"$nativeLisp/\")" \
        -f batch-native-compile "$siteLisp/site-start.el"
    ''}

    mkdir -p $out/share/info
    install ${selfInfo} $out/share/info/emacs-twist.info
    install-info $out/share/info/emacs-twist.info $out/share/info/dir

    for bin in $out/bin/*
    do
      if [[ $(basename $bin) = emacs-* ]]
      then
      wrapProgram $bin \
        ${lib.optionalString (length executablePackages > 0) (
          "--prefix PATH : ${lib.escapeShellArg (lib.makeBinPath executablePackages)}"
        )} \
        --prefix INFOPATH : ${emacs}/share/info:$out/share/info:${packageEnv}/share/info \
        ${lib.optionalString nativeComp "--set EMACSNATIVELOADPATH $nativeLisp:$nativeLoadPath"
        } \
        --set EMACSLOADPATH "$siteLisp:"
      fi
    done
  ''
