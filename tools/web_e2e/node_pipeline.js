const fs=require('fs'); const CV=require('/home/claude/smart-document-scanner/site/cv.js');
const cases=JSON.parse(fs.readFileSync('/tmp/jt/cases.json'));
const out=[];
for(const c of cases){
  const buf=new Uint8ClampedArray(fs.readFileSync(`/tmp/jt/${c.name}.rgba`));
  let t=Date.now(); const a=CV.analyze(buf,c.w,c.h, null); const ta=Date.now()-t;
  const p={corners:a.corners,dewarp:a.dewarp,mode:'document',paper:'auto',fineRotation:a.fineRotation};
  t=Date.now(); const r=CV.render(buf,c.w,c.h,p,1,null,true); const tr=Date.now()-t;
  fs.writeFileSync(`/tmp/jt/${c.name}_out.rgba`, Buffer.from(r.rgba.buffer));
  let err=null; if(c.truth&&a.corners){err=Math.max(...a.corners.map((q,i)=>Math.hypot(q.x-c.truth[i][0],q.y-c.truth[i][1])));}
  out.push({name:c.name,ow:r.w,oh:r.h,kind:a.kind,curv:a.curvature,conf:a.confidence,err,ta,tr,issues:a.issues.map(i=>i.code)});
}
fs.writeFileSync('/tmp/jt/res.json',JSON.stringify(out)); console.log(JSON.stringify(out,null,0));
