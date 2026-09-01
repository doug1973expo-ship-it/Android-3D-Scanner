package uk.co.pocket3d.scanner

import android.opengl.GLES20
import android.opengl.Matrix
import com.google.ar.core.Camera
import java.nio.ByteBuffer
import java.nio.ByteOrder

class GreenScanOverlay {
    private var program=0
    fun create(){
        val vertex="""uniform mat4 mvp;attribute vec3 position;void main(){gl_Position=mvp*vec4(position,1.0);gl_PointSize=clamp(15.0/gl_Position.w,10.0,28.0);}"""
        val fragment="""precision mediump float;void main(){vec2 p=gl_PointCoord-vec2(0.5);if(dot(p,p)>0.25)discard;gl_FragColor=vec4(0.08,0.95,0.28,0.30);}"""
        fun shader(type:Int,source:String)=GLES20.glCreateShader(type).also{GLES20.glShaderSource(it,source);GLES20.glCompileShader(it)}
        program=GLES20.glCreateProgram().also{GLES20.glAttachShader(it,shader(GLES20.GL_VERTEX_SHADER,vertex));GLES20.glAttachShader(it,shader(GLES20.GL_FRAGMENT_SHADER,fragment));GLES20.glLinkProgram(it)}
    }
    fun draw(camera:Camera,points:FloatArray){
        if(points.isEmpty())return
        val view=FloatArray(16);val projection=FloatArray(16);val mvp=FloatArray(16)
        camera.getViewMatrix(view,0);camera.getProjectionMatrix(projection,0,0.05f,20f)
        Matrix.multiplyMM(mvp,0,projection,0,view,0)
        val buffer=ByteBuffer.allocateDirect(points.size*4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply{put(points);position(0)}
        GLES20.glUseProgram(program)
        GLES20.glEnable(GLES20.GL_BLEND);GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA,GLES20.GL_ONE_MINUS_SRC_ALPHA)
        val pos=GLES20.glGetAttribLocation(program,"position");GLES20.glEnableVertexAttribArray(pos)
        GLES20.glVertexAttribPointer(pos,3,GLES20.GL_FLOAT,false,0,buffer)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program,"mvp"),1,false,mvp,0)
        GLES20.glDrawArrays(GLES20.GL_POINTS,0,points.size/3)
        GLES20.glDisableVertexAttribArray(pos);GLES20.glDisable(GLES20.GL_BLEND)
    }
}
