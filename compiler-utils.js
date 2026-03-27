export function replaceRefs(txt) {
  const regex = /^@.{2,20}\{.{2,50},/gm;
  const match = regex.exec(txt);
  if (match) {
    const bibIndex = match.index;
    return {
      bib: txt.substring(bibIndex),
      txt: txt.substring(0, bibIndex)
    };
  }

  return { bib: null, txt };
}
