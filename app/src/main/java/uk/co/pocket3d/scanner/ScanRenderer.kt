package uk.co.pocket3d.scanner
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import com.google.ar.core.*
import java.nio.ByteOrder
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
class ScanRenderer(private val activity:MainActivity,private val grid:VoxelGrid):GLSurfaceView.Renderer {
 private val background=CameraBackground();private val greenOverlay=GreenScanOverlay(); @Volatile var session:Session?=null; @Volatile var scanning=false; private var lastSample=0L
 private var overlayPoints=FloatArray(0);private var overlayCellCount=-1
 private var textureSession:Session?=null
 override fun onSurfaceCreated(gl:GL10?,config:EGLConfig?){GLES20.glClearColor(0f,0f,0f,1f);background.create();greenOverlay.create()}
 override fun onSurfaceChanged(gl:GL10?,w:Int,h:Int){GLES20.glViewport(0,0,w,h);session?.setDisplayGeometry(activity.windowManager.defaultDisplay.rotation,w,h)}
 override fun onDrawFrame(gl:GL10?){GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);val s=session?:return;try{if(textureSession!==s){s.setCameraTextureName(background.textureId);textureSession=s};val frame=s.update();if(frame.timestamp!=0L)background.draw(frame);if(scanning&&frame.camera.trackingState==TrackingState.TRACKING&&System.currentTimeMillis()-lastSample>350){sample(frame);lastSample=System.currentTimeMillis()};if(overlayCellCount!=grid.size){overlayPoints=grid.snapshotPoints();overlayCellCount=grid.size};greenOverlay.draw(frame.camera,overlayPoints)}catch(_:Throwable){}}
 private fun sample(frame:Frame){
  try{
   frame.acquireDepthImage16Bits().use{image->
    val intr=frame.camera.imageIntrinsics
    val dims=intr.imageDimensions
    val sx=image.width.toFloat()/dims[0];val sy=image.height.toFloat()/dims[1]
    val f=intr.focalLength;val c=intr.principalPoint
    val fx=f[0]*sx;val fy=f[1]*sy;val cx=c[0]*sx;val cy=c[1]*sy
    val plane=image.planes[0];val b=plane.buffer.order(ByteOrder.LITTLE_ENDIAN)
    val pose=frame.camera.pose;val step=6
    val left=(image.width*0.15f).toInt();val right=(image.width*0.85f).toInt()
    val top=(image.height*0.15f).toInt();val bottom=(image.height*0.85f).toInt()
    fun depth(u:Int,v:Int):Int{
     if(u !in 0 until image.width||v !in 0 until image.height)return 0
     val pos=v*plane.rowStride+u*plane.pixelStride
     return if(pos+1<b.limit())b.getShort(pos).toInt() and 0xffff else 0
    }
    for(v in top until bottom step step)for(u in left until right step step){
     val mm=depth(u,v);if(mm !in 150..1800)continue
     val tolerance=maxOf(35,(mm*0.04f).toInt())
     var neighbours=0
     if(kotlin.math.abs(depth(u-step,v)-mm)<tolerance)neighbours++
     if(kotlin.math.abs(depth(u+step,v)-mm)<tolerance)neighbours++
     if(kotlin.math.abs(depth(u,v-step)-mm)<tolerance)neighbours++
     if(kotlin.math.abs(depth(u,v+step)-mm)<tolerance)neighbours++
     if(neighbours<3)continue
     val z=mm/1000f
     val world=pose.transformPoint(floatArrayOf((u-cx)*z/fx,-(v-cy)*z/fy,-z))
     grid.add(world[0],world[1],world[2])
    }
   }
  }catch(_:NotYetAvailableException){}catch(_:Throwable){}
  activity.runOnUiThread{activity.updateCount(grid.size)}
 }
}
