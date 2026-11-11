const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const {test}=require('node:test');

const html=readFileSync(join(__dirname,'../codenotch/ui/notch.html'),'utf8');
function section(start,end){
  const from=html.indexOf(start),to=html.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing ${start}`);
  return html.slice(from,to);
}
const pointer=section('// Called by GTK crossing events','// Off the notch is off the orb');
function pointerPage(isLinux=true){
  const calls=[];
  const context=vm.createContext({
    window:{},isLinux,pointerIn:false,dragging:false,hideTimer:17,
    clearTimeout:id=>calls.push(['cancel',id]),unfold:()=>calls.push(['open']),
    setHovered:value=>calls.push(['handle',value]),hideCard:()=>calls.push(['close']),
    scheduleFold:()=>calls.push(['fold']),
  });
  vm.runInContext(pointer,context);
  return {context,calls};
}

test('Linux entering cancels a pending hide and opens the notch',()=>{
  const {context,calls}=pointerPage();
  context.window.codenotchPointer(true);
  assert.equal(context.pointerIn,true);
  assert.deepEqual(calls,[['cancel',17],['open']]);
});
test('Linux leaving closes the card and schedules folding',()=>{
  const {context,calls}=pointerPage();
  context.window.codenotchPointer(false);
  assert.equal(context.pointerIn,false);
  assert.deepEqual(calls,[['handle',null],['cancel',17],['close'],['fold']]);
});
test('leaving during a drag does not close or fold the notch',()=>{
  const {context,calls}=pointerPage();
  context.dragging=true;
  context.window.codenotchPointer(false);
  assert.deepEqual(calls,[]);
});
test('the GTK pointer entry point is not installed on Windows',()=>{
  assert.equal(pointerPage(false).context.window.codenotchPointer,undefined);
});

const contour=section('const isLinux=','/* Colour ramp');
function contourPage(edge='right',zoom=1,platform='Linux x86_64'){
  const nodes=[];
  const root={firstChild:null,insertBefore:node=>nodes.push(node)};
  const rect=['right','left'].includes(edge)
    ? {left:290*zoom,top:187*zoom,width:70*zoom,height:276*zoom}
    : {left:187*zoom,top:0,width:276*zoom,height:70*zoom};
  const context=vm.createContext({
    navigator:{platform},notchEdge:edge,pill:{getBoundingClientRect:()=>rect},
    edgeIsVertical:()=>['right','left'].includes(edge),
    getComputedStyle:()=>({getPropertyValue:()=> '38.7px'}),
    invoke:()=>new Promise(()=>{}),listen:()=>new Promise(()=>{}),
    document:{
      body:{classList:{toggle(){},add(){},remove(){}}},
      documentElement:{style:{zoom:String(zoom),setProperty(){}}},
      querySelector:()=>null,querySelectorAll:()=>[],
      getElementById:id=>id==='pill'?{getBoundingClientRect:()=>rect}:root,
      createElementNS:(namespaceURI,tag)=>({
        namespaceURI,tag,style:{},attributes:{},children:[],
        setAttribute(name,value){this.attributes[name]=value;},
        appendChild(child){this.children.push(child);},
      }),
    },
  });
  vm.runInContext(contour,context);
  context.paintPillContour();
  return {context,nodes,rect};
}
test('all four edges draw the body and both fillets in one SVG path',()=>{
  for(const edge of ['right','left','top','bottom']){
    const {context,nodes}=contourPage(edge);
    assert.equal(nodes.length,1,edge);
    assert.equal(nodes[0].children.length,2,edge);
    const path=nodes[0].children[1].attributes.d;
    assert.equal((path.match(/ A/g)||[]).length,2,`${edge}: both fillets are in the body path`);
    assert.doesNotMatch(path,/NaN|Infinity/,edge);
    context.paintPillContour();
    assert.equal(nodes.length,1,`${edge}: reuse the existing contour after layout updates`);
  }
});
test('the contour stays aligned with the pill under CSS zoom',()=>{
  const normal=contourPage('right'),scaled=contourPage('right',1.25);
  assert.equal(scaled.nodes[0].style.left,normal.nodes[0].style.left);
  assert.equal(scaled.nodes[0].style.top,normal.nodes[0].style.top);
  assert.equal(scaled.nodes[0].style.width,normal.nodes[0].style.width);
  assert.equal(scaled.nodes[0].style.height,normal.nodes[0].style.height);
});
test('Windows keeps its existing contour renderer when border anti-aliasing is off',()=>{
  const page=contourPage('right',1,'Win32');
  page.context.applyAntialiasBorder('off');
  assert.equal(page.nodes[0].style.display,'none');
});
